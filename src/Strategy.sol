// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IVault} from "@yearn-vaults/interfaces/IVault.sol";
import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {AggregatorInterface} from "./interfaces/AggregatorInterface.sol";
import {IVaultAPROracle} from "./interfaces/IVaultAPROracle.sol";
import {IAddressesRegistry, IBorrowerOperations, IPriceFeed, ITroveManager} from "./interfaces/IAddressesRegistry.sol";

import {BaseLenderBorrower, ERC20, Math} from "./BaseLenderBorrower.sol";

contract LiquityV2LBStrategy is BaseLenderBorrower {

    using SafeERC20 for ERC20;

    // ===============================================================
    // Storage
    // ===============================================================

    /// @notice Trove ID
    uint256 public troveId;

    // ===============================================================
    // Constants
    // ===============================================================

    /// @notice The difference in decimals between the AMM price (1e18) and our price (1e8)
    uint256 private constant DECIMALS_DIFF = 1e10;

    /// @notice Liquity's minimum amount of net Bold debt a trove must have
    ///         If a trove is redeeemed and the debt is less than this, it will be considered a zombie trove
    uint256 private constant MIN_DEBT = 2_000 * 1e18;

    /// @notice Liquity's amount of WETH to be locked in gas pool when opening a trove
    ///         Will be pulled from the contract on `_openTrove`
    uint256 private constant ETH_GAS_COMPENSATION = 0.0375 ether;

    /// @notice Minimum annual interest rate
    uint256 private constant MIN_ANNUAL_INTEREST_RATE = 1e18 / 100 / 2; // 0.5%

    /// @notice The governance address
    address public constant GOV = 0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52;

    /// @notice WETH token
    ERC20 private constant WETH = ERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    /// @notice The lender vault APR oracle contract
    IVaultAPROracle public constant VAULT_APR_ORACLE = IVaultAPROracle(0x1981AD9F44F2EA9aDd2dC4AD7D075c102C70aF92);

    /// @notice Same chainlink price feed as used by the Liquity branch
    AggregatorInterface public immutable PRICE_FEED;

    /// @notice Liquity's borrower operations contract
    IBorrowerOperations public immutable BORROWER_OPERATIONS;

    /// @notice Liquity's trove manager contract
    ITroveManager public immutable TROVE_MANAGER;

    // ===============================================================
    // Constructor
    // ===============================================================

    constructor(
        IAddressesRegistry _addressesRegistry,
        IVault _lenderVault,
        AggregatorInterface _priceFeed,
        string memory _name
    )
        BaseLenderBorrower(_addressesRegistry.collToken(), _name, _addressesRegistry.boldToken(), address(_lenderVault))
    {
        require(IStrategy(_lenderVault.asset()).asset() == borrowToken, "!lenderVault");

        BORROWER_OPERATIONS = _addressesRegistry.borrowerOperations();
        TROVE_MANAGER = _addressesRegistry.troveManager();
        PRICE_FEED =
            address(_priceFeed) == address(0) ? _addressesRegistry.priceFeed().ethUsdOracle().aggregator : _priceFeed;
        require(PRICE_FEED.decimals() == 8, "!priceFeed");

        asset.forceApprove(address(BORROWER_OPERATIONS), type(uint256).max);
        WETH.forceApprove(address(BORROWER_OPERATIONS), ETH_GAS_COMPENSATION);
    }

    // ===============================================================
    // Privileged functions
    // ===============================================================

    /// @notice Open a trove
    /// @dev
    ///     - Callable only once. If the position gets liquidated, we'll need to shutdown the strategy
    ///     - `asset` balance must be large enough to open a trove with `MIN_DEBT`
    ///     - Borrowing at the minimum interest rate, because we don't mind getting redeeemed
    /// @param _upperHint Upper hint
    /// @param _lowerHint Lower hint
    function openTrove(uint256 _upperHint, uint256 _lowerHint) external onlyEmergencyAuthorized {
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
        // @audit addManager/removeManager -- SMS, so can adjustZombieTrove?
    }

    /// @notice Claim remaining collateral from a liquidation
    function claimCollateral() external onlyEmergencyAuthorized {
        BORROWER_OPERATIONS.claimCollateral();
    }

    /// @notice Manually buy borrow token
    /// @dev Potentially can never reach `_buyBorrowToken()` in `_liquidatePosition()`
    ///      because of lender vault accounting (i.e. `balanceOfLentAssets() == 0` is never true)
    function buyBorrowToken(
        uint256 _amount
    ) external onlyEmergencyAuthorized {
        if (_amount == type(uint256).max) _amount = balanceOfAsset();
        _buyBorrowToken(_amount);
    }

    /// @notice Sweep of non-asset ERC20 tokens to governance
    /// @param _token The ERC20 token to sweep
    function sweep(
        ERC20 _token
    ) external {
        require(msg.sender == GOV, "!gov");
        require(_token != asset, "!asset");
        _token.safeTransfer(GOV, _token.balanceOf(address(this)));
    }

    // ===============================================================
    // Write functions
    // ===============================================================

    /// @inheritdoc BaseLenderBorrower
    function _tend(
        uint256 _totalIdle
    ) internal virtual override {
        _claimAndSellRewards();
        return BaseLenderBorrower._tend(_totalIdle);
    }

    /// @inheritdoc BaseLenderBorrower
    function _leveragePosition(
        uint256 _amount
    ) internal override {
        if (TROVE_MANAGER.getTroveStatus(troveId) != ITroveManager.Status.active) return;
        BaseLenderBorrower._leveragePosition(_amount);
    }

    /// @inheritdoc BaseLenderBorrower
    function _supplyCollateral(
        uint256 _amount
    ) internal override {
        if (_amount > 0) BORROWER_OPERATIONS.addColl(troveId, _amount);
    }

    /// @inheritdoc BaseLenderBorrower
    function _withdrawCollateral(
        uint256 _amount
    ) internal override {
        if (_amount > 0) BORROWER_OPERATIONS.withdrawColl(troveId, _amount);
    }

    /// @inheritdoc BaseLenderBorrower
    function _borrow(
        uint256 _amount
    ) internal override {
        if (_amount > 0) BORROWER_OPERATIONS.withdrawBold(troveId, _amount, type(uint256).max);
    }

    /// @inheritdoc BaseLenderBorrower
    function _repay(
        uint256 _amount
    ) internal override {
        if (_amount > 0) BORROWER_OPERATIONS.repayBold(troveId, _amount);
    }

    // ===============================================================
    // View functions
    // ===============================================================

    /// @inheritdoc BaseLenderBorrower
    function _tendTrigger() internal view override returns (bool) {
        if (TROVE_MANAGER.getTroveStatus(troveId) != ITroveManager.Status.active) return false;
        if (isRewardsToClaim() && _isBaseFeeAcceptable()) return true;
        return BaseLenderBorrower._tendTrigger();
    }

    /// @inheritdoc BaseLenderBorrower
    function _getPrice(
        address _asset
    ) internal view override returns (uint256) {
        return _asset == borrowToken ? WAD / DECIMALS_DIFF : uint256(PRICE_FEED.latestAnswer());
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
    function _maxBorrowAmount() internal view override returns (uint256) {
        return type(uint256).max;
    }

    /// @inheritdoc BaseLenderBorrower
    function getNetBorrowApr(
        uint256 /*_newAmount*/
    ) public view override returns (uint256) {
        return MIN_ANNUAL_INTEREST_RATE;
    }

    /// @inheritdoc BaseLenderBorrower
    function getNetRewardApr(
        uint256 _newAmount
    ) public view override returns (uint256) {
        return VAULT_APR_ORACLE.getExpectedApr(address(lenderVault), int256(_newAmount));
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

    function isRewardsToClaim() public view returns (bool) {
        // @todo
        return false;
    }

    // ===============================================================
    // Harvest / Token conversions
    // ===============================================================

    /// @inheritdoc BaseLenderBorrower
    function _claimRewards() internal pure override {
        return;
    }

    /// @inheritdoc BaseLenderBorrower
    function _claimAndSellRewards() internal override {
        uint256 _loose = balanceOfBorrowToken();
        uint256 _have = balanceOfLentAssets() + _loose;
        uint256 _owe = balanceOfDebt();
        if (_owe >= _have) return;

        uint256 _toSell = _have - _owe;
        if (_toSell > _loose) _withdrawBorrowToken(_toSell - _loose);

        _loose = balanceOfBorrowToken();

        _sellBorrowToken(Math.min(_toSell, _loose));
    }

    /// @inheritdoc BaseLenderBorrower
    function _sellBorrowToken(
        uint256 _amount
    ) internal virtual override {
        // AMM.exchange(CRVUSD_INDEX, ASSET_INDEX, _amount, 0);
        // BOLD --> ETH
        // @todo
        return;
    }

    /// @inheritdoc BaseLenderBorrower
    function _buyBorrowToken() internal virtual override {
        uint256 _borrowTokenStillOwed = borrowTokenOwedBalance();
        uint256 _maxAssetBalance = _fromUsd(_toUsd(_borrowTokenStillOwed, borrowToken), address(asset));
        _buyBorrowToken(_maxAssetBalance);
    }

    /// @notice Buy borrow token
    /// @param _amount The amount of asset to sale
    function _buyBorrowToken(
        uint256 _amount
    ) internal {
        // AMM.exchange(ASSET_INDEX, CRVUSD_INDEX, _amount, 0);
        // ETH --> BOLD
        // @todo
        return;
    }

}
