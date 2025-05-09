// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {BaseStrategy, ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAddressesRegistry, IBorrowerOperations, ITroveManager} from "./interfaces/IAddressesRegistry.sol";
import {ILiquityV2SPStrategy} from "./interfaces/ILiquityV2SPStrategy.sol";
import {IAuction, IAuctionFactory} from "./interfaces/IAuctionFactory.sol";
import {IPriceProvider} from "./interfaces/IPriceProvider.sol";

import {BaseLenderBorrower, Math} from "./BaseLenderBorrower.sol";

contract LiquityV2CarryTradeStrategy is BaseLenderBorrower {
    using SafeERC20 for ERC20;

    // ===============================================================
    // Storage
    // ===============================================================

    /// @notice Whether block withdrawals after a liquidation. Initialized to true
    bool public blockWithdrawalsAfterLiquidation;

    /// @notice Trove ID
    uint256 public troveId;

    /// @notice Buffer percentage for the auction starting price
    uint256 public auctionBufferPercentage;

    /// @notice Any amount below this will not be kicked
    uint256 public minKickAmount;

    // ===============================================================
    // Constants
    // ===============================================================

    /// @notice Any amount below this will be ignored
    uint256 private constant DUST_THRESHOLD = 10_000;

    /// @notice Minimum buffer percentage for the auction starting price
    uint256 private constant MIN_AUCTION_BUFFER_PERCENTAGE = WAD + 1e17; // 10%

    /// @notice Minimum amount of borrow token to be kicked
    uint256 private constant MIN_KICK_AMOUNT = 1e14;

    /// @notice Liquity's minimum amount of net Bold debt a trove must have
    ///         If a trove is redeeemed and the debt is less than this, it will be considered a zombie trove
    uint256 private constant MIN_DEBT = 2_000 * 1e18;

    /// @notice Liquity's amount of WETH to be locked in gas pool when opening a trove
    ///         Will be pulled from the contract on `_openTrove`
    uint256 private constant ETH_GAS_COMPENSATION = 0.0375 ether;

    /// @notice Minimum annual interest rate
    uint256 private constant MIN_ANNUAL_INTEREST_RATE = 1e18 / 100 / 2; // 0.5%

    /// @notice WETH token
    ERC20 private constant WETH = ERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    /// @notice Factory for creating the auction contract
    IAuctionFactory private constant AUCTION_FACTORY = IAuctionFactory(0xCfA510188884F199fcC6e750764FAAbE6e56ec40);

    /// @notice Auction contract for asset -> borrow token
    IAuction public immutable ASSET_TO_BORROW_AUCTION;

    /// @notice Auction contract for borrow token -> asset
    IAuction public immutable BORROW_TO_ASSET_AUCTION;

    /// @notice Price provider contract
    IPriceProvider public immutable PRICE_PROVIDER;

    /// @notice Liquity's borrower operations contract
    IBorrowerOperations public immutable BORROWER_OPERATIONS;

    /// @notice Liquity's trove manager contract
    ITroveManager public immutable TROVE_MANAGER;

    // ===============================================================
    // Constructor
    // ===============================================================

    /// @param _asset Address of the asset
    /// @param _name Name of the strategy
    /// @param _borrowToken Address of the borrow token
    /// @param _lenderVault Address of the lender vault
    /// @param _addressesRegistry Address of the Liquity's addresses registry
    /// @param _priceProvider Address of our price provider
    constructor(
        address _asset,
        string memory _name,
        address _borrowToken,
        address _lenderVault,
        address _addressesRegistry,
        address _priceProvider
    ) BaseLenderBorrower(_asset, _name, _borrowToken, _lenderVault) {
        ILiquityV2SPStrategy lenderVault_ = ILiquityV2SPStrategy(_lenderVault);
        require(lenderVault_.COLL() == _asset && lenderVault_.asset() == _borrowToken, "!lenderVault");

        IAddressesRegistry addressesRegistry_ = IAddressesRegistry(_addressesRegistry);
        require(
            addressesRegistry_.collToken() == _asset && addressesRegistry_.boldToken() == _borrowToken,
            "!addressesRegistry"
        );

        blockWithdrawalsAfterLiquidation = true;
        auctionBufferPercentage = MIN_AUCTION_BUFFER_PERCENTAGE;
        minKickAmount = MIN_KICK_AMOUNT;

        require(_priceProvider != address(0), "!priceProvider");
        PRICE_PROVIDER = IPriceProvider(_priceProvider);

        ASSET_TO_BORROW_AUCTION = AUCTION_FACTORY.createNewAuction(_borrowToken);
        ASSET_TO_BORROW_AUCTION.enable(_asset);

        BORROW_TO_ASSET_AUCTION = AUCTION_FACTORY.createNewAuction(_asset);
        BORROW_TO_ASSET_AUCTION.enable(_borrowToken);

        BORROWER_OPERATIONS = addressesRegistry_.borrowerOperations();
        TROVE_MANAGER = addressesRegistry_.troveManager();

        // NOTE: Never want to `_buyBorrowToken()` on `_liquidatePosition()` because no atomic swap
        //       Instead, if needed, buy borrow token manually
        leaveDebtBehind = true;

        asset.forceApprove(address(BORROWER_OPERATIONS), type(uint256).max);
        WETH.forceApprove(address(BORROWER_OPERATIONS), type(uint256).max);
    }

    // ===============================================================
    // Management functions
    // ===============================================================

    /// @notice Unblock withdrawals block after a liquidation
    /// @dev This will be used only when shutting down the strategy after a liquidation
    /// @dev We want to block by default because we may have auctioned the borrow token but not yet reported the loss
    /// @dev Once we've reported a loss, can unblock withdrawals
    function unblockWithdrawalsAfterLiquidation() external onlyManagement {
        blockWithdrawalsAfterLiquidation = false;
    }

    /// @notice Set the minimum amount of borrow token to be kicked
    /// @param _minKickAmount Minimum amount of borrow token to be kicked
    function setMinKickAmount(uint256 _minKickAmount) external onlyManagement {
        require(_minKickAmount >= MIN_KICK_AMOUNT, "!kick");
        minKickAmount = _minKickAmount;
    }

    /// @notice Set the buffer percentage for the auction starting price
    /// @param _auctionBufferPercentage Auction buffer percentage
    function setAuctionBufferPercentage(uint256 _auctionBufferPercentage) external onlyManagement {
        require(_auctionBufferPercentage >= MIN_AUCTION_BUFFER_PERCENTAGE, "!buffer");
        auctionBufferPercentage = _auctionBufferPercentage;
    }

    /// @notice Open a trove
    /// @dev Callable only after deployment or after liquidation
    /// @dev `asset` balance must be large enough to open a trove with `MIN_DEBT`
    /// @dev Borrowing at the minimum interest rate because we don't mind getting redeeemed
    /// @param _upperHint Upper hint
    /// @param _lowerHint Lower hint
    function openTrove(uint256 _upperHint, uint256 _lowerHint) external onlyManagement {
        require(troveId == 0, "troveId");
        uint256 _collAmount = balanceOfAsset();
        WETH.safeTransferFrom(msg.sender, address(this), ETH_GAS_COMPENSATION);
        troveId = BORROWER_OPERATIONS.openTrove(
            address(this), // owner
            block.timestamp, // ownerIndex
            _collAmount,
            MIN_DEBT, // boldAmount
            _upperHint,
            _lowerHint,
            MIN_ANNUAL_INTEREST_RATE, // annualInterestRate
            type(uint256).max, // maxUpfrontFee
            address(0), // addManager
            address(0), // removeManager
            address(0) // receiver
        );
    }

    /// @notice Claim remaining collateral from a liquidation with ICR exceeding the liquidation penalty
    function claimCollateral() external onlyManagement {
        BORROWER_OPERATIONS.claimCollateral();
    }

    // ===============================================================
    // Emergency authorized functions
    // ===============================================================

    /// @notice Buy borrow token
    /// @dev Calling this function will try to buy the full amount of the remaining debt
    ///      This may be necessary to unlock full collateral in case of wind down. Should not be called otherwise
    function buyBorrowToken() external onlyEmergencyAuthorized {
        _buyBorrowToken();
    }

    // ===============================================================
    // Keeper functions
    // ===============================================================

    /// @notice Auction off extra borrow token to asset
    /// @dev Should be called after a redemption/liquidation and when there's enough extra borrow token
    function kickRewards() external onlyKeepers {
        uint256 _have = balanceOfLentAssets() + balanceOfBorrowToken();
        uint256 _owe = balanceOfDebt();
        require(_have > _owe + minKickAmount, "!rewards");
        uint256 _extra = _have - _owe;
        _withdrawFromLender(_extra);
        _sellBorrowToken(Math.min(_extra, balanceOfBorrowToken()));
    }

    /// @notice Adjust zombie trove
    /// @dev Might need to be called after a redemption, if our debt is below `MIN_DEBT` (AKA zombie trove)
    /// @param _upperHint Upper hint
    /// @param _lowerHint Lower hint
    function adjustZombieTrove(uint256 _upperHint, uint256 _lowerHint) external onlyKeepers {
        BORROWER_OPERATIONS.adjustZombieTrove(
            troveId,
            balanceOfAsset(), // collChange
            true, // isCollIncrease
            MIN_DEBT - balanceOfDebt(), // boldChange
            true, // isDebtIncrease
            _upperHint,
            _lowerHint,
            type(uint256).max // maxUpfrontFee
        );

        uint256 _borrowTokenBalance = balanceOfBorrowToken();
        if (_borrowTokenBalance > 0) _lendBorrowToken(_borrowTokenBalance);
    }

    // ===============================================================
    // Public read functions
    // ===============================================================

    /// @inheritdoc BaseLenderBorrower
    function availableWithdrawLimit(address /*_owner*/ ) public view override returns (uint256) {
        if (
            TROVE_MANAGER.getTroveStatus(troveId) == ITroveManager.Status.closedByLiquidation
                && blockWithdrawalsAfterLiquidation
        ) return 0;
        return BaseLenderBorrower.availableWithdrawLimit(address(this));
    }

    /// @inheritdoc BaseLenderBorrower
    function getNetBorrowApr(uint256 /* newAmount */ ) public view override returns (uint256) {
        return TROVE_MANAGER.getLatestTroveData(troveId).annualInterestRate;
    }

    /// @inheritdoc BaseLenderBorrower
    function getNetRewardApr(uint256 /* newAmount */ ) public pure override returns (uint256) {
        return WAD; // Assuming reward APR will never be less than borrowing APR (0.5%)
    }

    /// @inheritdoc BaseLenderBorrower
    function getLiquidateCollateralFactor() public view override returns (uint256) {
        return WAD * WAD / BORROWER_OPERATIONS.MCR();
    }

    /// @inheritdoc BaseLenderBorrower
    function balanceOfCollateral() public view override returns (uint256) {
        return TROVE_MANAGER.getLatestTroveData(troveId).entireColl;
    }

    /// @inheritdoc BaseLenderBorrower
    function balanceOfDebt() public view override returns (uint256) {
        return TROVE_MANAGER.getLatestTroveData(troveId).entireDebt;
    }

    // ===============================================================
    // Internal write functions
    // ===============================================================

    /// @inheritdoc BaseLenderBorrower
    function _leveragePosition(uint256 _amount) internal override {
        if (TROVE_MANAGER.getTroveStatus(troveId) != ITroveManager.Status.active) return;
        BaseLenderBorrower._leveragePosition(_amount);
    }

    /// @inheritdoc BaseLenderBorrower
    function _deployFunds(uint256 _amount) internal override {
        _leveragePosition(_amount);
    }

    /// @inheritdoc BaseLenderBorrower
    function _supplyCollateral(uint256 _amount) internal override {
        if (_amount > DUST_THRESHOLD) BORROWER_OPERATIONS.addColl(troveId, _amount);
    }

    /// @inheritdoc BaseLenderBorrower
    function _withdrawCollateral(uint256 _amount) internal override {
        BORROWER_OPERATIONS.withdrawColl(troveId, _amount);
    }

    /// @inheritdoc BaseLenderBorrower
    function _borrow(uint256 _amount) internal override {
        BORROWER_OPERATIONS.withdrawBold(troveId, _amount, type(uint256).max);
    }

    /// @inheritdoc BaseLenderBorrower
    function _repay(uint256 _amount) internal override {
        if (_amount > 0) BORROWER_OPERATIONS.repayBold(troveId, _amount);
    }

    /// @inheritdoc BaseLenderBorrower
    /// @dev Calling this while trove is in zombie state might lead to stuck funds
    function _emergencyWithdraw(uint256 _amount) internal override {
        if (_amount > 0) _withdrawBorrowToken(Math.min(_amount, _lenderMaxWithdraw()));

        uint256 _troveId = troveId;
        if (TROVE_MANAGER.getTroveStatus(_troveId) == ITroveManager.Status.active) {
            BORROWER_OPERATIONS.closeTrove(_troveId);
            uint256 _balance = WETH.balanceOf(address(this));
            if (_balance > 0) WETH.safeTransfer(msg.sender, _balance);
        }
    }

    /// @inheritdoc BaseLenderBorrower
    function _buyBorrowToken() internal override {
        uint256 _borrowTokenStillOwed = borrowTokenOwedBalance();
        if (_borrowTokenStillOwed > 0) {
            uint256 _maxAssetBalance = _fromUsd(_toUsd(_borrowTokenStillOwed, borrowToken), address(asset));
            if (_maxAssetBalance <= DUST_THRESHOLD) return;
            uint256 _toAuction = _maxAssetBalance * (MAX_BPS + slippage) / MAX_BPS;
            // NOTE: Using the auction here could break `_liquidatePosition`
            _setAuctionStartingPrice(_toAuction, address(ASSET_TO_BORROW_AUCTION), address(asset));
            asset.safeTransfer(address(ASSET_TO_BORROW_AUCTION), _toAuction);
            ASSET_TO_BORROW_AUCTION.kick(address(asset));
        }
    }

    /// @inheritdoc BaseLenderBorrower
    function _sellBorrowToken(uint256 _amount) internal override {
        _setAuctionStartingPrice(_amount, address(BORROW_TO_ASSET_AUCTION), borrowToken);
        ERC20(borrowToken).safeTransfer(address(BORROW_TO_ASSET_AUCTION), _amount);
        BORROW_TO_ASSET_AUCTION.kick(borrowToken);
    }

    /// @notice Set the auction starting price
    /// @dev Should help setting the auction faster
    /// @param _toAuction Amount to auction
    /// @param _auction Auction contract
    /// @param _token Token to auction
    function _setAuctionStartingPrice(uint256 _toAuction, address _auction, address _token) internal {
        uint256 _price = _getPrice(_token);
        uint256 _available = ERC20(_token).balanceOf(_auction) + _toAuction;
        // slither-disable-next-line divide-before-multiply
        IAuction(_auction).setStartingPrice(_available * _price / WAD * auctionBufferPercentage / WAD);
    }

    // ===============================================================
    // Internal view functions
    // ===============================================================

    /// @inheritdoc BaseLenderBorrower
    function _getPrice(address _asset) internal view override returns (uint256 price) {
        return PRICE_PROVIDER.getPrice(_asset);
    }

    /// @inheritdoc BaseLenderBorrower
    function _isSupplyPaused() internal pure override returns (bool) {
        return false;
    }

    /// @inheritdoc BaseLenderBorrower
    function _isBorrowPaused() internal pure override returns (bool) {
        return false;
    }

    /// @inheritdoc BaseLenderBorrower
    function _isLiquidatable() internal view override returns (bool) {
        return TROVE_MANAGER.getCurrentICR(troveId, _getPrice(address(asset))) < BORROWER_OPERATIONS.MCR();
    }

    /// @inheritdoc BaseLenderBorrower
    function _maxCollateralDeposit() internal pure override returns (uint256) {
        return type(uint256).max;
    }

    /// @inheritdoc BaseLenderBorrower
    function _maxBorrowAmount() internal pure override returns (uint256) {
        return type(uint256).max;
    }

    /// @inheritdoc BaseLenderBorrower
    function _claimRewards() internal pure override {
        return; // No rewards to claim
    }

    /// @inheritdoc BaseLenderBorrower
    function _claimAndSellRewards() internal pure override {
        return; // Use `kickRewards()` instead
    }

    /// @inheritdoc BaseLenderBorrower
    function _tendTrigger() internal view override returns (bool) {
        if (TROVE_MANAGER.getTroveStatus(troveId) != ITroveManager.Status.active) return false;
        return BaseLenderBorrower._tendTrigger();
    }
}
