// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.24;

import {IStrategy} from "@tokenized-strategy/interfaces/IStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {TroveOps} from "./libraries/TroveOps.sol";
import {LenderOps} from "./libraries/LenderOps.sol";
import {LiquityMath} from "./libraries/LiquityMath.sol";

import {IExchange} from "./interfaces/IExchange.sol";
import {AggregatorInterface} from "./interfaces/AggregatorInterface.sol";
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

    /// @notice Trove ID
    uint256 public troveId;

    /// @notice Absolute surplus required (in BOLD) before tending is considered
    /// @dev Initialized to `50` in the constructor
    uint256 public minSurplusAbsolute;

    /// @notice Relative surplus required (in basis points) of current debt, before tending is considered
    /// @dev Initialized to `100` (1%) in the constructor
    uint256 public minSurplusRelative;

    /// @notice Allowed slippage (in basis points) when swapping tokens
    /// @dev Initialized to `9_500` (5%) in the constructor
    uint256 public allowedSwapSlippageBps;

    /// @notice Addresses allowed to deposit
    mapping(address => bool) public allowed;

    // ===============================================================
    // Constants
    // ===============================================================

    /// @notice Precision used by the price feed
    uint256 private constant _PRICE_PRECISION = 1e8;

    /// @notice The difference in decimals between our price oracle (1e8) and Liquity's price oracle (1e18)
    uint256 private constant _DECIMALS_DIFF = 1e10;

    /// @notice Maximum relative surplus required (in basis points) before tending is considered
    uint256 private constant _MAX_RELATIVE_SURPLUS = 1000; // 10%

    /// @notice The branch minimum collateral ratio (MCR)
    uint256 private immutable _MCR;

    /// @notice The branch critical collateral ratio (CCR)
    uint256 private immutable _CCR;

    /// @notice WETH token
    ERC20 private constant _WETH = ERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    /// @notice Same Chainlink price feed as used by the Liquity branch
    AggregatorInterface public immutable PRICE_FEED;

    /// @notice Liquity's borrower operations contract
    IBorrowerOperations public immutable BORROWER_OPERATIONS;

    /// @notice Liquity's trove manager contract
    ITroveManager public immutable TROVE_MANAGER;

    /// @notice Liquity's collateral surplus pool contract
    ICollSurplusPool public immutable COLL_SURPLUS_POOL;

    /// @notice The exchange contract for buying/selling the borrow token
    IExchange public immutable EXCHANGE;

    // ===============================================================
    // Constructor
    // ===============================================================

    /// @param _addressesRegistry The Liquity addresses registry contract
    /// @param _priceFeed The price feed contract for the `asset`
    /// @param _exchange The exchange contract for buying/selling borrow token
    /// @param _name The name of the strategy
    constructor(
        IAddressesRegistry _addressesRegistry,
        AggregatorInterface _priceFeed,
        IExchange _exchange,
        string memory _name
    )
        BaseLenderBorrower(
            _addressesRegistry.collToken(), // asset
            _name,
            _addressesRegistry.boldToken(), // borrowToken
            address(LenderOps.LENDER_VAULT) // lenderVault
        )
    {
        require(_exchange.BORROW() == borrowToken && _exchange.COLLATERAL() == address(asset), "!exchange");

        minSurplusAbsolute = 50e18; // 50 BOLD
        minSurplusRelative = 100; // 1%
        allowedSwapSlippageBps = 9500; // 5%

        BORROWER_OPERATIONS = _addressesRegistry.borrowerOperations();
        TROVE_MANAGER = _addressesRegistry.troveManager();
        COLL_SURPLUS_POOL = _addressesRegistry.collSurplusPool();
        PRICE_FEED =
            address(_priceFeed) == address(0) ? _addressesRegistry.priceFeed().ethUsdOracle().aggregator : _priceFeed;
        require(PRICE_FEED.decimals() == 8, "!priceFeed");
        EXCHANGE = _exchange;

        _MCR = BORROWER_OPERATIONS.MCR();
        _CCR = BORROWER_OPERATIONS.CCR();

        ERC20(address(lenderVault)).forceApprove(address(LenderOps.STAKED_LENDER_VAULT), type(uint256).max);
        ERC20(borrowToken).forceApprove(address(EXCHANGE), type(uint256).max);
        asset.forceApprove(address(EXCHANGE), type(uint256).max);
        asset.forceApprove(address(BORROWER_OPERATIONS), type(uint256).max);
        if (asset != _WETH) _WETH.forceApprove(address(BORROWER_OPERATIONS), TroveOps.ETH_GAS_COMPENSATION);
    }

    // ===============================================================
    // Privileged functions
    // ===============================================================

    /// @notice Open a trove
    /// @dev Callable only once. If the position gets liquidated, we'll need to shutdown the strategy
    /// @dev `asset` balance must be large enough to open a trove with `MIN_DEBT`
    /// @dev Requires the caller to pay the gas compensation in WETH
    /// @dev Should be called through a private RPC to avoid fee slippage
    /// @param _upperHint Upper hint
    /// @param _lowerHint Lower hint
    function openTrove(
        uint256 _upperHint,
        uint256 _lowerHint
    ) external onlyEmergencyAuthorized {
        require(troveId == 0, "troveId");

        // Mint `MIN_DEBT` and use all the collateral we have
        troveId = TroveOps.openTrove(BORROWER_OPERATIONS, balanceOfAsset(), _upperHint, _lowerHint);

        // Lend everything we have
        _lendBorrowToken(balanceOfBorrowToken());
    }

    /// @notice Adjust the interest rate of the trove
    /// @dev Will fail if the trove is not active
    /// @dev Should be called through a private RPC to avoid fee slippage
    /// @dev Would incur an upfront fee if the adjustment is considered premature (i.e. within 7 days of last adjustment)
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

    /// @notice Adjust zombie trove
    /// @dev Might need to be called after a redemption if our debt is below `MIN_DEBT`
    /// @dev Will fail if the trove is not in zombie mode
    /// @dev Should be called through a private RPC to avoid fee slippage
    /// @param _upperHint Upper hint
    /// @param _lowerHint Lower hint
    function adjustZombieTrove(
        uint256 _upperHint,
        uint256 _lowerHint
    ) external onlyEmergencyAuthorized {
        // Mint just enough to get the trove out of zombie mode, using all the collateral we have
        TroveOps.adjustZombieTrove(
            BORROWER_OPERATIONS, troveId, balanceOfAsset(), balanceOfDebt(), _upperHint, _lowerHint
        );

        // Lend everything we have
        _lendBorrowToken(balanceOfBorrowToken());
    }

    /// @notice Set the surplus detection floors used by `hasBorrowTokenSurplus()`
    /// @param _minSurplusAbsolute Absolute minimum surplus required, in borrow token units
    /// @param _minSurplusRelative Relative minimum surplus required, as basis points of current debt
    function setSurplusFloors(
        uint256 _minSurplusAbsolute,
        uint256 _minSurplusRelative
    ) external onlyManagement {
        require(_minSurplusRelative <= _MAX_RELATIVE_SURPLUS, "!relativeSurplus");
        minSurplusAbsolute = _minSurplusAbsolute;
        minSurplusRelative = _minSurplusRelative;
    }

    /// @notice Set the allowed swap slippage (in basis points)
    /// @dev E.g., 9_500 = 5% slippage allowed
    /// @param _allowedSwapSlippageBps The allowed swap slippage
    function setAllowedSwapSlippageBps(
        uint256 _allowedSwapSlippageBps
    ) external onlyManagement {
        require(_allowedSwapSlippageBps <= MAX_BPS, "!allowedSwapSlippageBps");
        allowedSwapSlippageBps = _allowedSwapSlippageBps;
    }

    /// @notice Allow (or disallow) a specific address to deposit into the strategy
    /// @dev Deposits can trigger new borrows, and Liquity charges an upfront fee on
    ///      every debt increase. If deposits were permissionless, a malicious actor
    ///      could repeatedly deposit/withdraw small amounts to force the strategy
    ///      to borrow and pay the fee many times, socializing those costs across
    ///      existing depositors. To prevent this griefing vector, deposits are gated
    /// @param _address Address to allow or disallow
    /// @param _allowed True to allow deposits from `_address`, false to block
    function setAllowed(
        address _address,
        bool _allowed
    ) external onlyManagement {
        allowed[_address] = _allowed;
    }

    /// @notice Sweep of non-asset ERC20 tokens
    /// @param _token The ERC20 token to sweep
    function sweep(
        ERC20 _token
    ) external onlyManagement {
        require(_token != asset, "!asset");
        _token.safeTransfer(TokenizedStrategy.management(), _token.balanceOf(address(this)));
    }

    // ===============================================================
    // Write functions
    // ===============================================================

    /// @inheritdoc BaseLenderBorrower
    function _leveragePosition(
        uint256 _amount
    ) internal override {
        // Do nothing if the trove is not active
        if (TROVE_MANAGER.getTroveStatus(troveId) != ITroveManager.Status.active) return;

        // Otherwise, business as usual
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
        // `repayBold()` makes sure we don't go below `MIN_DEBT`
        if (_amount > 0) BORROWER_OPERATIONS.repayBold(troveId, _amount);
    }

    // ===============================================================
    // View functions
    // ===============================================================

    /// @inheritdoc BaseLenderBorrower
    function availableDepositLimit(
        address _owner
    ) public view override returns (uint256) {
        // We check `_owner == address(this)` because BaseLenderBorrower uses `availableDepositLimit(address(this))`
        return allowed[_owner] || _owner == address(this) ? BaseLenderBorrower.availableDepositLimit(_owner) : 0;
    }

    /// @inheritdoc BaseLenderBorrower
    /// @dev Returns the maximum collateral that can be withdrawn without reducing
    ///      the branch’s total collateral ratio (TCR) below the critical collateral ratio (CCR).
    ///      Withdrawal is limited by both:
    ///        - the CCR constraint at the branch level, and
    ///        - the base withdrawal constraints in BaseLenderBorrower
    function _maxWithdrawal() internal view override returns (uint256) {
        // Cache values for later use
        uint256 _price = _getPrice(address(asset)) * _DECIMALS_DIFF;
        uint256 _branchDebt = BORROWER_OPERATIONS.getEntireBranchDebt();
        uint256 _branchCollateral = BORROWER_OPERATIONS.getEntireBranchColl();

        // Collateral required to keep TCR >= CCR
        uint256 _requiredColl = Math.ceilDiv(_CCR * _branchDebt, _price);

        // Max collateral removable while staying >= CCR
        uint256 _headroomByCCR = _branchCollateral > _requiredColl ? _branchCollateral - _requiredColl : 0;

        // Final cap is the tighter of CCR constraint and base withdrawal cap
        return Math.min(_headroomByCCR, BaseLenderBorrower._maxWithdrawal());
    }

    /// @inheritdoc BaseLenderBorrower
    function _getPrice(
        address _asset
    ) internal view override returns (uint256) {
        // Not bothering with price feed checks because it's the same one Liquity uses
        return _asset == borrowToken ? WAD / _DECIMALS_DIFF : uint256(PRICE_FEED.latestAnswer());
    }

    /// @inheritdoc BaseLenderBorrower
    function _isSupplyPaused() internal view override returns (bool) {
        return BORROWER_OPERATIONS.hasBeenShutDown();
    }

    /// @inheritdoc BaseLenderBorrower
    function _isBorrowPaused() internal view override returns (bool) {
        // When the branch TCR falls below the CCR, BorrowerOperations blocks `withdrawBold()`,
        // in that case we should not attempt to borrow.
        // When TCR >= CCR, our own target (<= 90% of MCR) is stricter than the CCR requirement,
        // so don’t need to impose an additional cap in `_maxBorrowAmount()`
        return _isTCRBelowCCR() || BORROWER_OPERATIONS.hasBeenShutDown();
    }

    /// @inheritdoc BaseLenderBorrower
    function _isLiquidatable() internal view override returns (bool) {
        // `getCurrentICR()` expects the price to be in 1e18 format
        return TROVE_MANAGER.getCurrentICR(troveId, _getPrice(address(asset)) * _DECIMALS_DIFF) < _MCR;
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
    ) public pure override returns (uint256) {
        return 0; // Assumes always profitable to borrow
    }

    /// @inheritdoc BaseLenderBorrower
    function getNetRewardApr(
        uint256 /*_newAmount*/
    ) public pure override returns (uint256) {
        return 1; // Assumes always profitable to borrow
    }

    /// @inheritdoc BaseLenderBorrower
    function getLiquidateCollateralFactor() public view override returns (uint256) {
        return WAD * WAD / _MCR;
    }

    /// @inheritdoc BaseLenderBorrower
    function balanceOfCollateral() public view override returns (uint256) {
        return TROVE_MANAGER.getLatestTroveData(troveId).entireColl;
    }

    /// @inheritdoc BaseLenderBorrower
    function balanceOfDebt() public view override returns (uint256) {
        return TROVE_MANAGER.getLatestTroveData(troveId).entireDebt;
    }

    /// @notice Returns true when we hold more borrow token than we owe by a _meaningful_ margin
    /// @dev Purpose is to detect redemptions/liquidations while avoiding action on normal profit
    /// @return True if `surplus > max(absoluteFloor, relativeFloor)`
    function hasBorrowTokenSurplus() public view returns (bool) {
        uint256 _loose = balanceOfBorrowToken();
        uint256 _have = balanceOfLentAssets() + _loose;
        uint256 _owe = balanceOfDebt();
        if (_have <= _owe) return false;

        // Positive surplus we could realize by selling borrow token back to collateral
        uint256 _surplus = _have - _owe;

        // Use the stricter of the two floors (absolute or relative)
        uint256 _floor = Math.max(
            minSurplusAbsolute, // Absolute floor
            _owe * minSurplusRelative / MAX_BPS // Relative floor (some percentage of current debt)
        );

        // Consider surplus only when higher than the higher floor
        return _surplus > _floor;
    }

    /// @notice Check if the branch Total Collateral Ratio (TCR) has fallen below the Critical Collateral Ratio (CCR)
    /// @return True if TCR < CCR, false otherwise
    function _isTCRBelowCCR() internal view returns (bool) {
        return LiquityMath._computeCR(
            BORROWER_OPERATIONS.getEntireBranchColl(),
            BORROWER_OPERATIONS.getEntireBranchDebt(),
            _getPrice(address(asset)) * _DECIMALS_DIFF // LiquityMath expects 1e18 format
        ) < _CCR;
    }

    // ===============================================================
    // Lender vault
    // ===============================================================

    /// @inheritdoc BaseLenderBorrower
    function _lendBorrowToken(
        uint256 _amount
    ) internal override {
        LenderOps.lend(_amount);
    }

    /// @inheritdoc BaseLenderBorrower
    function _withdrawBorrowToken(
        uint256 _amount
    ) internal override {
        LenderOps.withdraw(_amount);
    }

    /// @inheritdoc BaseLenderBorrower
    function _lenderMaxDeposit() internal view override returns (uint256) {
        return LenderOps.maxDeposit();
    }

    /// @inheritdoc BaseLenderBorrower
    function _lenderMaxWithdraw() internal view override returns (uint256) {
        return LenderOps.maxWithdraw();
    }

    /// @inheritdoc BaseLenderBorrower
    function balanceOfLentAssets() public view override returns (uint256) {
        return LenderOps.balanceOfAssets();
    }

    // ===============================================================
    // Harvest / Token conversions
    // ===============================================================

    /// @inheritdoc BaseLenderBorrower
    function _tendTrigger() internal view override returns (bool) {
        // If base fee is acceptable and we have a borrow token surplus (likely from redemption/liquidation),
        // tend to (1) minimize exchange rate exposure and (2) minimize the risk of someone using our borrowing capacity
        // before we manage to borrow again, such that any new debt we take will lead to TCR < CCR
        //
        // (2) chain of events: [1] we are redeemed [2] we have no debt but some collateral
        // [3] someone hops in and uses our collateral to borrow above CCR [4] we cannot take new debt because it will lead to TCR < CCR
        if (_isBaseFeeAcceptable() && hasBorrowTokenSurplus()) return true;

        // If the trove is not active, do nothing
        if (TROVE_MANAGER.getTroveStatus(troveId) != ITroveManager.Status.active) return false;

        // Finally, business as usual
        return BaseLenderBorrower._tendTrigger();
    }

    /// @inheritdoc BaseLenderBorrower
    function _tend(
        uint256 /*_totalIdle*/
    ) internal override {
        // Sell any surplus borrow token
        _claimAndSellRewards();

        // Using `balanceOfAsset()` because `_totalIdle` may increase after selling borrow token surplus
        return BaseLenderBorrower._tend(balanceOfAsset());
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
        // Calculate the expected amount of collateral out
        uint256 _expectedAmountOut = _amount * _PRICE_PRECISION / _getPrice(address(asset));

        // Apply slippage tolerance
        uint256 _minAmountOut = _expectedAmountOut * allowedSwapSlippageBps / MAX_BPS;

        // Swap away
        EXCHANGE.swap(
            _amount,
            _minAmountOut, // minAmount
            true // fromBorrow
        );
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
        // Calculate the expected amount of borrow token out
        uint256 _expectedAmountOut = _amount * _getPrice(address(asset)) / _PRICE_PRECISION;

        // Apply slippage tolerance
        uint256 _minAmountOut = _expectedAmountOut * allowedSwapSlippageBps / MAX_BPS;

        // Swap away
        EXCHANGE.swap(
            _amount,
            _minAmountOut, // minAmount
            false // fromBorrow
        );
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
