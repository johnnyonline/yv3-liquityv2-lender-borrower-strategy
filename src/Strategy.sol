// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {TroveOps} from "./libraries/TroveOps.sol";
import {LenderOps} from "./libraries/LenderOps.sol";

import {IExchange} from "./interfaces/IExchange.sol";
import {AggregatorInterface} from "./interfaces/AggregatorInterface.sol";
import {IVaultAPROracle} from "./interfaces/IVaultAPROracle.sol";
import {
    IAddressesRegistry,
    IBorrowerOperations,
    ICollSurplusPool,
    ITroveManager
} from "./interfaces/IAddressesRegistry.sol";

import {BaseLenderBorrower, ERC20, Math} from "./BaseLenderBorrower.sol";

contract LiquityV2LBStrategy is BaseLenderBorrower {

    using SafeERC20 for ERC20;

    // ===============================================================
    // Storage
    // ===============================================================

    /// @notice If true, `getNetBorrowApr()` will return 0,
    ///         which means we'll always consider it profitable to borrow
    bool public forceLeverage;

    /// @notice Trove ID
    uint256 public troveId;

    /// @notice Any amount below this will be ignored
    uint256 public dustThreshold;

    /// @notice Mapping of addresses that can `adjustTroveInterestRate()`
    mapping(address => bool) public isZombieSlayer;

    // ===============================================================
    // Constants
    // ===============================================================

    /// @notice The difference in decimals between the AMM price (1e18) and our price (1e8)
    uint256 private constant DECIMALS_DIFF = 1e10;

    /// @notice Minimum dust threshold
    uint256 public constant MIN_DUST_THRESHOLD = 1e15;

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

    /// @notice Liquity's collateral surplus pool contract
    ICollSurplusPool public immutable COLL_SURPLUS_POOL;

    /// @notice The exchange contract for buying/selling borrow token
    IExchange public immutable EXCHANGE;

    /// @notice The staked lender vault contract (i.e. st-yBOLD)
    IStrategy public immutable STAKED_LENDER_VAULT;

    // ===============================================================
    // Constructor
    // ===============================================================

    /// @param _addressesRegistry The Liquity addresses registry contract
    /// @param _stakedLenderVault The staked lender vault contract (i.e. st-yBOLD)
    /// @param _priceFeed The price feed contract for the `asset`
    /// @param _exchange The exchange contract for buying/selling borrow token
    /// @param _name The name of the strategy
    constructor(
        IAddressesRegistry _addressesRegistry,
        IStrategy _stakedLenderVault,
        AggregatorInterface _priceFeed,
        IExchange _exchange,
        string memory _name
    )
        BaseLenderBorrower(
            _addressesRegistry.collToken(), // asset
            _name,
            _addressesRegistry.boldToken(), // borrowToken
            _stakedLenderVault.asset() // lenderVault
        )
    {
        require(_exchange.TOKEN() == borrowToken && _exchange.PAIRED_WITH() == address(asset), "!exchange");

        forceLeverage = true;
        dustThreshold = MIN_DUST_THRESHOLD;

        BORROWER_OPERATIONS = _addressesRegistry.borrowerOperations();
        TROVE_MANAGER = _addressesRegistry.troveManager();
        COLL_SURPLUS_POOL = _addressesRegistry.collSurplusPool();
        PRICE_FEED =
            address(_priceFeed) == address(0) ? _addressesRegistry.priceFeed().ethUsdOracle().aggregator : _priceFeed;
        require(PRICE_FEED.decimals() == 8, "!priceFeed");
        EXCHANGE = _exchange;
        STAKED_LENDER_VAULT = _stakedLenderVault;

        ERC20(address(lenderVault)).forceApprove(address(STAKED_LENDER_VAULT), type(uint256).max);
        ERC20(borrowToken).forceApprove(address(EXCHANGE), type(uint256).max);
        asset.forceApprove(address(EXCHANGE), type(uint256).max);
        asset.forceApprove(address(BORROWER_OPERATIONS), type(uint256).max);
        if (asset != WETH) WETH.forceApprove(address(BORROWER_OPERATIONS), TroveOps.ETH_GAS_COMPENSATION);
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
        troveId = TroveOps.openTrove(BORROWER_OPERATIONS, balanceOfAsset(), _upperHint, _lowerHint);
        _lendBorrowToken(balanceOfBorrowToken());
    }

    /// @notice Adjust the interest rate of the trove
    /// @dev Will fail if the trove is not active
    /// @param _newAnnualInterestRate New annual interest rate
    /// @param _upperHint Upper hint
    /// @param _lowerHint Lower hint
    function adjustTroveInterestRate(
        uint256 _newAnnualInterestRate,
        uint256 _upperHint,
        uint256 _lowerHint
    ) external onlyEmergencyAuthorized {
        TroveOps.adjustTroveInterestRate(BORROWER_OPERATIONS, troveId, _newAnnualInterestRate, _upperHint, _lowerHint);
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

    /// @notice Set the dust threshold for the strategy
    /// @param _dustThreshold New dust threshold
    function setDustThreshold(
        uint256 _dustThreshold
    ) external onlyManagement {
        require(_dustThreshold >= MIN_DUST_THRESHOLD, "!minDust");
        dustThreshold = _dustThreshold;
    }

    /// @notice Set the forceLeverage flag
    /// @param _forceLeverage The new value for the forceLeverage flag
    function setForceLeverage(
        bool _forceLeverage
    ) external onlyManagement {
        forceLeverage = _forceLeverage;
    }

    /// @notice Allow an address to call `adjustTroveInterestRate()`
    /// @param _zombieSlayer The address to set as a zombie slayer
    /// @param _isSlayer Whether the address is a zombie slayer
    function setZombieSlayer(
        address _zombieSlayer,
        bool _isSlayer
    ) external onlyManagement {
        isZombieSlayer[_zombieSlayer] = _isSlayer;
    }

    /// @notice Adjust zombie trove
    /// @dev Might need to be called after a redemption, if our debt is below `MIN_DEBT`
    /// @param _upperHint Upper hint
    /// @param _lowerHint Lower hint
    function adjustZombieTrove(uint256 _upperHint, uint256 _lowerHint) external {
        require(isZombieSlayer[msg.sender], "!zombieSlayer");
        require(TROVE_MANAGER.getTroveStatus(troveId) == ITroveManager.Status.zombie, "!zombie");
        TroveOps.adjustZombieTrove(
            BORROWER_OPERATIONS, troveId, balanceOfAsset(), balanceOfDebt(), _upperHint, _lowerHint
        );
        _lendBorrowToken(balanceOfBorrowToken());
    }

    /// @notice Sweep of non-asset ERC20 tokens to governance
    /// @param _token The ERC20 token to sweep
    function sweep(
        ERC20 _token
    ) external {
        require(msg.sender == GOV, "toopleb");
        require(_token != asset, "!asset");
        _token.safeTransfer(GOV, _token.balanceOf(address(this)));
    }

    // ===============================================================
    // Write functions
    // ===============================================================

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
        uint256 _debt = balanceOfDebt();
        uint256 _minDebt = TroveOps.MIN_DEBT;
        if (_debt - _amount < _minDebt) _amount = _debt - _minDebt;
        if (_amount > 0) BORROWER_OPERATIONS.repayBold(troveId, _amount);
    }

    // ===============================================================
    // View functions
    // ===============================================================

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
        return
            TROVE_MANAGER.getCurrentICR(troveId, _getPrice(address(asset)) * DECIMALS_DIFF) < BORROWER_OPERATIONS.MCR();
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
    function getNetBorrowApr(
        uint256 /*_newAmount*/
    ) public view override returns (uint256) {
        return forceLeverage ? 0 : TROVE_MANAGER.getLatestTroveData(troveId).annualInterestRate;
    }

    /// @inheritdoc BaseLenderBorrower
    function getNetRewardApr(
        uint256 _newAmount
    ) public view override returns (uint256) {
        return VAULT_APR_ORACLE.getStrategyApr(address(STAKED_LENDER_VAULT), int256(_newAmount));
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
        uint256 _loose = balanceOfBorrowToken();
        uint256 _have = balanceOfLentAssets() + _loose;
        uint256 _owe = balanceOfDebt();
        return _have > _owe && _have - _owe > dustThreshold;
    }

    // ===============================================================
    // Lender vault
    // ===============================================================

    /// @inheritdoc BaseLenderBorrower
    function _lendBorrowToken(
        uint256 amount
    ) internal override {
        LenderOps.lend(STAKED_LENDER_VAULT, lenderVault, amount);
    }

    /// @inheritdoc BaseLenderBorrower
    function _withdrawBorrowToken(
        uint256 amount
    ) internal override {
        LenderOps.withdraw(STAKED_LENDER_VAULT, lenderVault, amount);
    }

    /// @inheritdoc BaseLenderBorrower
    function _lenderMaxDeposit() internal view override returns (uint256) {
        return LenderOps.maxDeposit(STAKED_LENDER_VAULT, lenderVault);
    }

    /// @inheritdoc BaseLenderBorrower
    function _lenderMaxWithdraw() internal view override returns (uint256) {
        return LenderOps.maxWithdraw(STAKED_LENDER_VAULT, lenderVault);
    }

    /// @inheritdoc BaseLenderBorrower
    function balanceOfLentAssets() public view override returns (uint256) {
        return LenderOps.balanceOfAssets(STAKED_LENDER_VAULT, lenderVault);
    }

    // ===============================================================
    // Harvest / Token conversions
    // ===============================================================

    /// @inheritdoc BaseLenderBorrower
    function _tendTrigger() internal view override returns (bool) {
        if (isRewardsToClaim() && _isBaseFeeAcceptable()) return true;
        if (TROVE_MANAGER.getTroveStatus(troveId) != ITroveManager.Status.active) return false;
        return BaseLenderBorrower._tendTrigger();
    }

    /// @inheritdoc BaseLenderBorrower
    function _tend(
        uint256 _totalIdle
    ) internal override {
        _claimAndSellRewards();
        return BaseLenderBorrower._tend(_totalIdle);
    }

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
    ) internal override {
        EXCHANGE.swap(_amount, 0, true);
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
        EXCHANGE.swap(_amount, 0, false);
    }

    /// @inheritdoc BaseLenderBorrower
    function _emergencyWithdraw(
        uint256 _amount
    ) internal override {
        if (_amount > 0) _withdrawBorrowToken(Math.min(_amount, _lenderMaxWithdraw()));
        TroveOps.onEmergencyWithdraw(
            TROVE_MANAGER, BORROWER_OPERATIONS, COLL_SURPLUS_POOL, TokenizedStrategy.management(), troveId
        );
    }

}
