// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.23;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaseHealthCheck, ERC20} from "@periphery/Bases/HealthCheck/BaseHealthCheck.sol";
import "forge-std/console2.sol";
/**
 * @title Base Lender Borrower
 */

abstract contract BaseLenderBorrower is BaseHealthCheck {

    using SafeERC20 for ERC20;

    uint256 internal constant WAD = 1e18;

    /// The token we will be borrowing/supplying.
    address public immutable borrowToken;

    /// If set to true, the strategy will not try to repay debt by selling rewards or asset.
    bool public leaveDebtBehind;

    /// @notice Target Loan-To-Value (LTV) multiplier in Basis Points
    /// @dev Represents the ratio up to which we will borrow, relative to the liquidation threshold.
    /// LTV is the debt-to-collateral ratio. Default is set to 70% of the liquidation LTV.
    uint16 public targetLTVMultiplier;

    /// @notice Warning Loan-To-Value (LTV) multiplier in Basis Points
    /// @dev Represents the ratio at which we will start repaying the debt to avoid liquidation
    /// Default is set to 80% of the liquidation LTV
    uint16 public warningLTVMultiplier; // 80% of liquidation LTV

    /// @notice Slippage tolerance (in basis points) for swaps
    uint64 public slippage;

    /// @notice Deposit limit for the strategy.
    uint256 public depositLimit;

    /// The max the base fee (in gwei) will be for a tend
    uint256 public maxGasPriceToTend;

    /// Thresholds: lower limit on how much base token can be borrowed at a time.
    // slither-disable-next-line uninitialized-state
    uint256 internal minAmountToBorrow;

    /// The lender vault that will be used to lend and borrow.
    IERC4626 public immutable lenderVault;

    /**
     * @param _asset The address of the asset we are lending/borrowing.
     * @param _name The name of the strategy.
     * @param _borrowToken The address of the borrow token.
     */
    constructor(
        address _asset,
        string memory _name,
        address _borrowToken,
        address _lenderVault
    ) BaseHealthCheck(_asset, _name) {
        borrowToken = _borrowToken;

        // Set default variables
        depositLimit = type(uint256).max;
        targetLTVMultiplier = 7_000;
        warningLTVMultiplier = 8_000;
        leaveDebtBehind = false;
        maxGasPriceToTend = 200 * 1e9;
        slippage = 500;

        // Allow for address(0) for versions that don't use 4626 vault.
        if (_lenderVault != address(0)) {
            lenderVault = IERC4626(_lenderVault);
            require(lenderVault.asset() == _borrowToken, "!lenderVault");
            ERC20(_borrowToken).safeApprove(_lenderVault, type(uint256).max);
        }
    }

    /// ----------------- SETTERS -----------------

    /**
     * @notice Set the deposit limit for the strategy
     * @param _depositLimit New deposit limit
     */
    function setDepositLimit(
        uint256 _depositLimit
    ) external onlyManagement {
        depositLimit = _depositLimit;
    }

    /**
     * @notice Set the target and warning LTV multipliers
     * @param _targetLTVMultiplier New target LTV multiplier
     * @param _warningLTVMultiplier New warning LTV multiplier
     * @dev Target must be less than warning, warning must be <= 9000, target cannot be 0
     */
    function setLtvMultipliers(uint16 _targetLTVMultiplier, uint16 _warningLTVMultiplier) external onlyManagement {
        require(
            _warningLTVMultiplier <= 9_000 && _targetLTVMultiplier < _warningLTVMultiplier && _targetLTVMultiplier != 0,
            "invalid LTV"
        );
        targetLTVMultiplier = _targetLTVMultiplier;
        warningLTVMultiplier = _warningLTVMultiplier;
    }

    /**
     * @notice Set whether to leave debt behind
     * @param _leaveDebtBehind New leave debt behind setting
     */
    function setLeaveDebtBehind(
        bool _leaveDebtBehind
    ) external onlyManagement {
        leaveDebtBehind = _leaveDebtBehind;
    }

    /**
     * @notice Set the maximum gas price for tending
     * @param _maxGasPriceToTend New maximum gas price
     */
    function setMaxGasPriceToTend(
        uint256 _maxGasPriceToTend
    ) external onlyManagement {
        maxGasPriceToTend = _maxGasPriceToTend;
    }

    /**
     * @notice Set the slippage tolerance
     * @param _slippage New slippage tolerance in basis points
     */
    function setSlippage(
        uint256 _slippage
    ) external onlyManagement {
        require(_slippage < MAX_BPS, "slippage");
        slippage = uint64(_slippage);
    }

    /*//////////////////////////////////////////////////////////////
                NEEDED TO BE OVERRIDDEN BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Should deploy up to '_amount' of 'asset' in the yield source.
     *
     * This function is called at the end of a {deposit} or {mint}
     * call. Meaning that unless a whitelist is implemented it will
     * be entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * @param _amount The amount of 'asset' that the strategy should attempt
     * to deposit in the yield source.
     */
    function _deployFunds(
        uint256 _amount
    ) internal virtual override {
        _leveragePosition(_amount);
    }

    /**
     * @dev Will attempt to free the '_amount' of 'asset'.
     *
     * The amount of 'asset' that is already loose has already
     * been accounted for.
     *
     * This function is called during {withdraw} and {redeem} calls.
     * Meaning that unless a whitelist is implemented it will be
     * entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * Should not rely on asset.balanceOf(address(this)) calls other than
     * for diff accounting purposes.
     *
     * Any difference between `_amount` and what is actually freed will be
     * counted as a loss and passed on to the withdrawer. This means
     * care should be taken in times of illiquidity. It may be better to revert
     * if withdraws are simply illiquid so not to realize incorrect losses.
     *
     * @param _amount, The amount of 'asset' to be freed.
     */
    function _freeFunds(
        uint256 _amount
    ) internal virtual override {
        _liquidatePosition(_amount);
    }

    /**
     * @dev Internal function to harvest all rewards, redeploy any idle
     * funds and return an accurate accounting of all funds currently
     * held by the Strategy.
     *
     * This should do any needed harvesting, rewards selling, accrual,
     * redepositing etc. to get the most accurate view of current assets.
     *
     * NOTE: All applicable assets including loose assets should be
     * accounted for in this function.
     *
     * Care should be taken when relying on oracles or swap values rather
     * than actual amounts as all Strategy profit/loss accounting will
     * be done based on this returned value.
     *
     * This can still be called post a shutdown, a strategist can check
     * `TokenizedStrategy.isShutdown()` to decide if funds should be
     * redeployed or simply realize any profits/losses.
     *
     * @return _totalAssets A trusted and accurate account for the total
     * amount of 'asset' the strategy currently holds including idle funds.
     */
    function _harvestAndReport() internal virtual override returns (uint256 _totalAssets) {
        /// 1. claim rewards, 2. even borrowToken deposits and borrows 3. sell remainder of rewards to asset.
        _claimAndSellRewards();

        /// Leverage all the asset we have or up to the supply cap.
        /// We want check our leverage even if balance of asset is 0.
        _leveragePosition(Math.min(balanceOfAsset(), availableDepositLimit(address(this))));

        /// Base token owed should be 0 here but we count it just in case
        _totalAssets = balanceOfAsset() + balanceOfCollateral() - _borrowTokenOwedInAsset();
    }

    /*//////////////////////////////////////////////////////////////
                    OPTIONAL TO OVERRIDE BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Optional function for strategist to override that can
     *  be called in between reports.
     *
     * If '_tend' is used tendTrigger() will also need to be overridden.
     *
     * This call can only be called by a permissioned role so may be
     * through protected relays.
     *
     * This can be used to harvest and compound rewards, deposit idle funds,
     * perform needed position maintenance or anything else that doesn't need
     * a full report for.
     *
     *   EX: A strategy that can not deposit funds without getting
     *       sandwiched can use the tend when a certain threshold
     *       of idle to totalAssets has been reached.
     *
     * The TokenizedStrategy contract will do all needed debt and idle updates
     * after this has finished and will have no effect on PPS of the strategy
     * till report() is called.
     *
     * @param _totalIdle The current amount of idle funds that are available to deploy.
     */
    function _tend(
        uint256 _totalIdle
    ) internal virtual override {
        /// If the cost to borrow > rewards rate we will pull out all funds to not report a loss
        if (getNetBorrowApr(0) > getNetRewardApr(0)) {
            /// Liquidate everything so not to report a loss
            _liquidatePosition(balanceOfCollateral());
            /// Return since we don't asset to do anything else
            return;
        }

        /// Else we need to either adjust LTV up or down.
        _leveragePosition(Math.min(_totalIdle, availableDepositLimit(address(this))));
    }

    /**
     * @dev Optional trigger to override if tend() will be used by the strategy.
     * This must be implemented if the strategy hopes to invoke _tend().
     *
     * @return . Should return true if tend() should be called by keeper or false if not.
     */
    function _tendTrigger() internal view virtual override returns (bool) {
        /// If we are in danger of being liquidated tend no matter what
        if (_isLiquidatable()) return true;

        if (TokenizedStrategy.totalAssets() == 0) return false;

        /// We adjust position if:
        /// 1. LTV ratios are not in the HEALTHY range (either we take on more debt or repay debt)
        /// 2. costs are acceptable
        uint256 collateralInUsd = _toUsd(balanceOfCollateral(), address(asset));
        uint256 debtInUsd = _toUsd(balanceOfDebt(), borrowToken);
        uint256 currentLTV = collateralInUsd > 0 ? (debtInUsd * WAD) / collateralInUsd : 0;

        /// Check if we are over our warning LTV
        if (currentLTV > _getWarningLTV()) return true;

        if (_isSupplyPaused() || _isBorrowPaused()) return false;

        uint256 targetLTV = _getTargetLTV();

        /// If we are still levered and Borrowing costs are too high.
        if (currentLTV != 0 && getNetBorrowApr(0) > getNetRewardApr(0)) {
            /// Tend if base fee is acceptable.
            return _isBaseFeeAcceptable();

            /// IF we are lower than our target. (we need a 10% (1000bps) difference)
        } else if ((currentLTV < targetLTV && targetLTV - currentLTV > 1e17)) {
            /// Make sure the increase in debt would keep borrowing costs healthy.
            uint256 targetDebtUsd = (collateralInUsd * targetLTV) / WAD;

            uint256 amountToBorrowUsd;
            unchecked {
                amountToBorrowUsd = targetDebtUsd - debtInUsd; // safe bc we checked ratios
            }

            /// Convert to borrowToken
            uint256 amountToBorrowBT =
                Math.min(_fromUsd(amountToBorrowUsd, borrowToken), Math.min(_lenderMaxDeposit(), _maxBorrowAmount()));

            if (amountToBorrowBT == 0) return false;

            /// We want to make sure that the reward apr > borrow apr so we don't report a loss
            /// Borrowing will cause the borrow apr to go up and the rewards apr to go down
            if (getNetBorrowApr(amountToBorrowBT) < getNetRewardApr(amountToBorrowBT)) {
                /// Borrowing costs are healthy and WE NEED TO TAKE ON MORE DEBT
                return _isBaseFeeAcceptable();
            }
        }

        return false;
    }

    /**
     * @notice Gets the max amount of `asset` that an address can deposit.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overridden by strategists.
     *
     * This function will be called before any deposit or mints to enforce
     * any limits desired by the strategist. This can be used for either a
     * traditional deposit limit or for implementing a whitelist etc.
     *
     *   EX:
     *      if(isAllowed[_owner]) return super.availableDepositLimit(_owner);
     *
     * This does not need to take into account any conversion rates
     * from shares to assets. But should know that any non max uint256
     * amounts may be converted to shares. So it is recommended to keep
     * custom amounts low enough as not to cause overflow when multiplied
     * by `totalSupply`.
     *
     * @param . The address that is depositing into the strategy.
     * @return . The available amount the `_owner` can deposit in terms of `asset`
     */
    function availableDepositLimit(
        address /*_owner*/
    ) public view virtual override returns (uint256) {
        /// We need to be able to both supply and withdraw on deposits.
        if (_isSupplyPaused() || _isBorrowPaused()) return 0;

        uint256 currentAssets = TokenizedStrategy.totalAssets();
        uint256 limit = depositLimit > currentAssets ? depositLimit - currentAssets : 0;

        uint256 maxDeposit = Math.min(_maxCollateralDeposit(), limit);
        uint256 maxBorrow = Math.min(_lenderMaxDeposit(), _maxBorrowAmount());

        // Either the max supply or the max we could borrow / targetLTV.
        return Math.min(maxDeposit, _fromUsd((_toUsd(maxBorrow, borrowToken) * WAD) / _getTargetLTV(), address(asset)));
    }

    /**
     * @notice Gets the max amount of `asset` that can be withdrawn.
     * @dev Defaults to an unlimited amount for any address. But can
     * be overridden by strategists.
     *
     * This function will be called before any withdraw or redeem to enforce
     * any limits desired by the strategist. This can be used for illiquid
     * or sandwichable strategies. It should never be lower than `totalIdle`.
     *
     *   EX:
     *       return TokenIzedStrategy.totalIdle();
     *
     * This does not need to take into account the `_owner`'s share balance
     * or conversion rates from shares to assets.
     *
     * @param . The address that is withdrawing from the strategy.
     * @return . The available amount that can be withdrawn in terms of `asset`
     */
    function availableWithdrawLimit(
        address /*_owner*/
    ) public view virtual override returns (uint256) {
        /// Default liquidity is the balance of collateral + 1 for rounding.
        uint256 liquidity = balanceOfCollateral() + 1;
        uint256 lenderLiquidity = _lenderMaxWithdraw();

        /// If we can't withdraw or supply, set liquidity = 0.
        if (lenderLiquidity < balanceOfLentAssets()) {
            /// Adjust liquidity based on withdrawing the full amount of debt.
            unchecked {
                liquidity = ((_fromUsd(_toUsd(lenderLiquidity, borrowToken), address(asset)) * WAD) / _getTargetLTV());
            }
        }

        return balanceOfAsset() + liquidity;
    }

    /// ----------------- INTERNAL FUNCTIONS SUPPORT ----------------- \\

    /**
     * @notice Adjusts the leverage position of the strategy based on current and target Loan-to-Value (LTV) ratios.
     * @dev All debt and collateral calculations are done in USD terms. LTV values are represented in 1e18 format.
     * @param _amount The amount to be supplied to adjust the leverage position,
     */
    function _leveragePosition(
        uint256 _amount
    ) internal virtual {
        /// Supply the given amount to the strategy.
        // This function internally checks for zero amounts.
        _supplyCollateral(_amount);

        uint256 collateralInUsd = _toUsd(balanceOfCollateral(), address(asset));

        /// Convert debt to USD
        uint256 debtInUsd = _toUsd(balanceOfDebt(), borrowToken);

        /// LTV numbers are always in WAD
        uint256 currentLTV = collateralInUsd > 0 ? (debtInUsd * WAD) / collateralInUsd : 0;
        uint256 targetLTV = _getTargetLTV(); // 70% under default liquidation Threshold

        /// decide in which range we are and act accordingly:
        /// SUBOPTIMAL(borrow) (e.g. from 0 to 70% liqLTV)
        /// HEALTHY(do nothing) (e.g. from 70% to 80% liqLTV)
        /// UNHEALTHY(repay) (e.g. from 80% to 100% liqLTV)
        if (targetLTV > currentLTV) {
            /// SUBOPTIMAL RATIO: our current Loan-to-Value is lower than what we want

            /// we need to take on more debt
            uint256 targetDebtUsd = (collateralInUsd * targetLTV) / WAD;

            uint256 amountToBorrowUsd;
            unchecked {
                amountToBorrowUsd = targetDebtUsd - debtInUsd; // safe bc we checked ratios
            }

            /// convert to borrowToken
            uint256 amountToBorrowBT =
                Math.min(_fromUsd(amountToBorrowUsd, borrowToken), Math.min(_lenderMaxDeposit(), _maxBorrowAmount()));

            /// We want to make sure that the reward apr > borrow apr so we don't report a loss
            /// Borrowing will cause the borrow apr to go up and the rewards apr to go down
            if (getNetBorrowApr(amountToBorrowBT) > getNetRewardApr(amountToBorrowBT)) {
                /// If we would push it over the limit don't borrow anything
                amountToBorrowBT = 0;
            }

            /// Need to have at least the min threshold
            if (amountToBorrowBT > minAmountToBorrow) _borrow(amountToBorrowBT);
        } else if (currentLTV > _getWarningLTV()) {
            /// UNHEALTHY RATIO
            /// we repay debt to set it to targetLTV
            uint256 targetDebtUsd = (targetLTV * collateralInUsd) / WAD;

            /// Withdraw the difference from the Depositor
            _withdrawFromLender(_fromUsd(debtInUsd - targetDebtUsd, borrowToken));

            /// Repay the borrowToken debt.
            _repayTokenDebt();
        }

        // Deposit any loose base token that was borrowed.
        uint256 borrowTokenBalance = balanceOfBorrowToken();
        if (borrowTokenBalance > 0) _lendBorrowToken(borrowTokenBalance);
    }

    /**
     * @notice Liquidates the position to ensure the needed amount while maintaining healthy ratios.
     * @dev All debt, collateral, and needed amounts are calculated in USD. The needed amount is represented in the asset.
     * @param _needed The amount required in the asset.
     */
    function _liquidatePosition(
        uint256 _needed
    ) internal virtual {
        /// Cache balance for withdraw checks
        uint256 balance = balanceOfAsset();

        /// We first repay whatever we need to repay to keep healthy ratios
        _withdrawFromLender(_calculateAmountToRepay(_needed));

        /// we repay the borrowToken debt with the amount withdrawn from the vault
        _repayTokenDebt();

        // Withdraw as much as we can up to the amount needed while maintaining a health ltv
        _withdrawCollateral(Math.min(_needed, _maxWithdrawal()));

        /// We check if we withdrew less than expected, and we do have not more borrowToken
        /// left AND should harvest or buy borrowToken with asset (potentially realising losses)
        if (
            /// if we didn't get enough
            /// still some debt remaining
            /// but no capital to repay
            /// And the leave debt flag is false.
            _needed > balanceOfAsset() - balance && balanceOfDebt() > 0 && balanceOfLentAssets() == 0
                && !leaveDebtBehind
        ) {
            /// using this part of code may result in losses but it is necessary to unlock full collateral
            /// in case of wind down. This should only occur when depleting the strategy so we buy the full
            /// amount of our remaining debt. We buy borrowToken first with available rewards then with asset.
            _buyBorrowToken();

            /// we repay debt to actually unlock collateral
            /// after this, balanceOfDebt should be 0
            _repayTokenDebt();

            /// then we try withdraw once more
            /// still withdraw with target LTV since management can potentially save any left over manually
            _withdrawCollateral(_maxWithdrawal());
        }
    }

    /**
     * @notice Calculates max amount that can be withdrawn while maintaining healthy LTV ratio
     * @dev Considers current collateral and debt amounts
     * @return The max amount of collateral available for withdrawal
     */
    function _maxWithdrawal() internal view virtual returns (uint256) {
        uint256 collateral = balanceOfCollateral();
        uint256 debt = balanceOfDebt();

        /// If there is no debt we can withdraw everything
        if (debt == 0) return collateral;

        uint256 debtInUsd = _toUsd(debt, borrowToken);

        /// What we need to maintain a health LTV
        uint256 neededCollateral = _fromUsd((debtInUsd * WAD) / _getTargetLTV(), address(asset));

        /// We need more collateral so we cant withdraw anything
        if (neededCollateral > collateral) return 0;

        /// Return the difference in terms of asset
        unchecked {
            return collateral - neededCollateral;
        }
    }

    /**
     * @notice Calculates amount of debt to repay to maintain healthy LTV ratio
     * @dev Considers target LTV, amount being withdrawn, and current collateral/debt
     * @param amount The withdrawal amount
     * @return The amount of debt to repay
     */
    function _calculateAmountToRepay(
        uint256 amount
    ) internal view virtual returns (uint256) {
        if (amount == 0) return 0;
        uint256 collateral = balanceOfCollateral();
        /// To unlock all collateral we must repay all the debt
        if (amount >= collateral) return balanceOfDebt();

        /// We check if the collateral that we are withdrawing leaves us in a risky range, we then take action
        uint256 newCollateralUsd = _toUsd(collateral - amount, address(asset));

        uint256 targetDebtUsd = (newCollateralUsd * _getTargetLTV()) / WAD;
        uint256 targetDebt = _fromUsd(targetDebtUsd, borrowToken);
        uint256 currentDebt = balanceOfDebt();
        /// Repay only if our target debt is lower than our current debt
        return targetDebt < currentDebt ? currentDebt - targetDebt : 0;
    }

    /**
     * @notice Repays outstanding debt with available base tokens
     * @dev Repays debt by supplying base tokens up to the min of available balance and debt amount
     */
    function _repayTokenDebt() internal virtual {
        /// We cannot pay more than loose balance or more than we owe
        _repay(Math.min(balanceOfBorrowToken(), balanceOfDebt()));
    }

    /**
     * @notice Withdraws a specified amount of `borrowToken` from the lender.
     * @param amount The amount of the borrowToken to withdraw.
     */
    function _withdrawFromLender(
        uint256 amount
    ) internal virtual {
        uint256 balancePrior = balanceOfBorrowToken();
        /// Only withdraw what we don't already have free
        amount = balancePrior >= amount ? 0 : amount - balancePrior;

        /// Make sure we have enough balance.
        amount = Math.min(amount, _lenderMaxWithdraw());

        if (amount == 0) return;

        _withdrawBorrowToken(amount);
    }

    // ----------------- INTERNAL WRITE FUNCTIONS ----------------- \\

    /**
     * @notice Supplies a specified amount of `asset` as collateral.
     * @param amount The amount of the asset to supply.
     */
    function _supplyCollateral(
        uint256 amount
    ) internal virtual;

    /**
     * @notice Withdraws a specified amount of collateral.
     * @param amount The amount of the collateral to withdraw.
     */
    function _withdrawCollateral(
        uint256 amount
    ) internal virtual;

    /**
     * @notice Borrows a specified amount of `borrowToken`.
     * @param amount The amount of the borrowToken to borrow.
     */
    function _borrow(
        uint256 amount
    ) internal virtual;

    /**
     * @notice Repays a specified amount of `borrowToken`.
     * @param amount The amount of the borrowToken to repay.
     */
    function _repay(
        uint256 amount
    ) internal virtual;

    /**
     * @notice Lends a specified amount of `borrowToken`.
     * @param amount The amount of the borrowToken to lend.
     */
    function _lendBorrowToken(
        uint256 amount
    ) internal virtual {
        lenderVault.deposit(amount, address(this));
    }

    /**
     * @notice Withdraws a specified amount of `borrowToken`.
     * @param amount The amount of the borrowToken to withdraw.
     */
    function _withdrawBorrowToken(
        uint256 amount
    ) internal virtual {
        // Use previewWithdraw to round up.
        uint256 shares = Math.min(lenderVault.previewWithdraw(amount), lenderVault.balanceOf(address(this)));
        lenderVault.redeem(shares, address(this), address(this));
    }

    // ----------------- INTERNAL VIEW FUNCTIONS ----------------- \\

    /**
     * @notice Gets asset price returned 1e8
     * @param _asset The asset address
     * @return price asset price
     */
    function _getPrice(
        address _asset
    ) internal view virtual returns (uint256 price);

    /**
     * @notice Checks if lending or borrowing is paused
     * @return True if paused, false otherwise
     */
    function _isSupplyPaused() internal view virtual returns (bool);

    /**
     * @notice Checks if borrowing is paused
     * @return True if paused, false otherwise
     */
    function _isBorrowPaused() internal view virtual returns (bool);

    /**
     * @notice Checks if the strategy is liquidatable
     * @return True if liquidatable, false otherwise
     */
    function _isLiquidatable() internal view virtual returns (bool);

    /**
     * @notice Gets the supply cap for the collateral asset if any
     * @return The supply cap
     */
    function _maxCollateralDeposit() internal view virtual returns (uint256);

    /**
     * @notice Gets the max amount of `borrowToken` that could be borrowed
     * @return The max borrow amount
     */
    function _maxBorrowAmount() internal view virtual returns (uint256);

    /**
     * @notice Gets the max amount of `borrowToken` that could be deposited to the lender
     * @return The max deposit amount
     */
    function _lenderMaxDeposit() internal view virtual returns (uint256) {
        return lenderVault.maxDeposit(address(this));
    }

    /**
     * @notice Gets the amount of borrowToken that could be withdrawn from the lender
     * @return The lender liquidity
     */
    function _lenderMaxWithdraw() internal view virtual returns (uint256) {
        return lenderVault.convertToAssets(lenderVault.maxRedeem(address(this)));
    }

    /**
     * @notice Gets net borrow APR from depositor
     * @param newAmount Simulated supply amount
     * @return Net borrow APR
     */
    function getNetBorrowApr(
        uint256 newAmount
    ) public view virtual returns (uint256);

    /**
     * @notice Gets net reward APR from depositor
     * @param newAmount Simulated supply amount
     * @return Net reward APR
     */
    function getNetRewardApr(
        uint256 newAmount
    ) public view virtual returns (uint256);

    /**
     * @notice Gets liquidation collateral factor for asset
     * @return Liquidation collateral factor
     */
    function getLiquidateCollateralFactor() public view virtual returns (uint256);

    /**
     * @notice Gets supplied collateral balance
     * @return Collateral balance
     */
    function balanceOfCollateral() public view virtual returns (uint256);

    /**
     * @notice Gets current borrow balance
     * @return Borrow balance
     */
    function balanceOfDebt() public view virtual returns (uint256);

    /**
     * @notice Gets full depositor balance
     * @return Depositor balance
     */
    function balanceOfLentAssets() public view virtual returns (uint256) {
        return lenderVault.convertToAssets(lenderVault.balanceOf(address(this)));
    }

    /**
     * @notice Gets available balance of asset token
     * @return The asset token balance
     */
    function balanceOfAsset() public view virtual returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /**
     * @notice Gets available base token balance
     * @return Base token balance
     */
    function balanceOfBorrowToken() public view virtual returns (uint256) {
        return ERC20(borrowToken).balanceOf(address(this));
    }

    /**
     * @notice Gets net owed base tokens (borrowed - supplied)
     * @return Net base tokens owed
     */
    function borrowTokenOwedBalance() public view virtual returns (uint256) {
        uint256 have = balanceOfLentAssets() + balanceOfBorrowToken();
        uint256 owe = balanceOfDebt();

        /// If they are the same or supply > debt return 0
        if (have >= owe) return 0;

        unchecked {
            return owe - have;
        }
    }

    /**
     * @notice Gets base tokens owed in asset terms
     * @return owed tokens owed in asset value
     */
    function _borrowTokenOwedInAsset() internal view virtual returns (uint256 owed) {
        /// Don't do conversions unless it's a non-zero false.
        uint256 owedInBase = borrowTokenOwedBalance();
        if (owedInBase != 0) owed = _fromUsd(_toUsd(owedInBase, borrowToken), address(asset));
    }

    /**
     * @notice Calculates current loan-to-value ratio
     * @dev Converts collateral and debt values to USD
     * @return Current LTV in 1e18 format
     */
    function getCurrentLTV() external view virtual returns (uint256) {
        uint256 collateral = balanceOfCollateral();

        if (collateral == 0) return 0;

        unchecked {
            return (_toUsd(balanceOfDebt(), borrowToken) * WAD) / _toUsd(collateral, address(asset));
        }
    }

    /**
     * @notice Gets target loan-to-value ratio
     * @dev Calculates based on liquidation threshold and multiplier
     * @return Target LTV in 1e18 format
     */
    function _getTargetLTV() internal view virtual returns (uint256) {
        unchecked {
            return (getLiquidateCollateralFactor() * targetLTVMultiplier) / MAX_BPS;
        }
    }

    /**
     * @notice Gets warning loan-to-value ratio
     * @dev Calculates based on liquidation threshold and multiplier
     * @return Warning LTV in 1e18 format
     */
    function _getWarningLTV() internal view virtual returns (uint256) {
        unchecked {
            return (getLiquidateCollateralFactor() * warningLTVMultiplier) / MAX_BPS;
        }
    }

    /**
     * @notice Converts a token amount to USD value
     * @dev This assumes _getPrice returns constants 1e8 price
     * @param _amount The token amount
     * @param _token The token address
     * @return The USD value scaled by 1e8
     */
    function _toUsd(uint256 _amount, address _token) internal view virtual returns (uint256) {
        if (_amount == 0) return 0;
        unchecked {
            return (_amount * _getPrice(_token)) / (10 ** ERC20(_token).decimals());
        }
    }

    /**
     * @notice Converts a USD amount to token value
     * @dev This assumes _getPrice returns constants 1e8 price
     * @param _amount The USD amount (scaled by 1e8)
     * @param _token The token address
     * @return The token amount
     */
    function _fromUsd(uint256 _amount, address _token) internal view virtual returns (uint256) {
        if (_amount == 0) return 0;
        unchecked {
            return (_amount * (10 ** ERC20(_token).decimals())) / _getPrice(_token);
        }
    }

    /// ----------------- HARVEST / TOKEN CONVERSIONS -----------------

    /**
     * @notice Claims reward tokens.
     */
    function _claimRewards() internal virtual;

    /**
     * @notice Claims and sells available reward tokens
     * @dev Handles claiming, selling rewards for borrow tokens if needed, and selling remaining rewards for asset
     */
    function _claimAndSellRewards() internal virtual;

    /**
     * @dev Buys the borrow token using the strategy's assets.
     * This function should only ever be called when withdrawing all funds from the strategy if there is debt left over.
     * Initially, it tries to sell rewards for the needed amount of base token, then it will swap assets.
     * Using this function in a standard withdrawal can cause it to be sandwiched, which is why rewards are used first.
     */
    function _buyBorrowToken() internal virtual;

    /**
     * @dev Will swap from the base token => underlying asset.
     */
    function _sellBorrowToken(
        uint256 _amount
    ) internal virtual;

    /**
     * @notice Estimates swap output accounting for slippage
     * @param _amount Input amount
     * @param _from Input token
     * @param _to Output token
     * @return Estimated output amount
     */
    function _getAmountOut(uint256 _amount, address _from, address _to) internal view virtual returns (uint256) {
        if (_amount == 0) return 0;

        return (_fromUsd(_toUsd(_amount, _from), _to) * (MAX_BPS - slippage)) / MAX_BPS;
    }

    /**
     * @notice Checks if base fee is acceptable
     * @return True if base fee is below threshold
     */
    function _isBaseFeeAcceptable() internal view virtual returns (bool) {
        return block.basefee <= maxGasPriceToTend;
    }

    /**
     * @dev Optional function for a strategist to override that will
     * allow management to manually withdraw deployed funds from the
     * yield source if a strategy is shutdown.
     *
     * This should attempt to free `_amount`, noting that `_amount` may
     * be more than is currently deployed.
     *
     * NOTE: This will not realize any profits or losses. A separate
     * {report} will be needed in order to record any profit/loss. If
     * a report may need to be called after a shutdown it is important
     * to check if the strategy is shutdown during {_harvestAndReport}
     * so that it does not simply re-deploy all funds that had been freed.
     *
     * EX:
     *   if(freeAsset > 0 && !TokenizedStrategy.isShutdown()) {
     *       depositFunds...
     *    }
     *
     * @param _amount The amount of asset to attempt to free.
     */
    function _emergencyWithdraw(
        uint256 _amount
    ) internal virtual override {
        if (_amount > 0) _withdrawBorrowToken(Math.min(_amount, _lenderMaxWithdraw()));

        // Repay everything we can.
        _repayTokenDebt();

        // Withdraw all that makes sense.
        _withdrawCollateral(_maxWithdrawal());
    }

    // Manually Sell rewards
    function claimAndSellRewards() external virtual onlyEmergencyAuthorized {
        _claimAndSellRewards();
    }

    /// @notice Sell a specific amount of `borrowToken` -> asset.
    ///     The amount of borrowToken should be loose in the strategy before this is called
    ///     max uint input will sell any excess borrowToken we have.
    function sellBorrowToken(
        uint256 _amount
    ) external virtual onlyEmergencyAuthorized {
        if (_amount == type(uint256).max) {
            uint256 _balanceOfBorrowToken = balanceOfBorrowToken();
            _amount = Math.min(balanceOfLentAssets() + _balanceOfBorrowToken - balanceOfDebt(), _balanceOfBorrowToken);
        }
        _sellBorrowToken(_amount);
    }

    /// @notice Withdraw a specific amount of `_token`
    function manualWithdraw(address _token, uint256 _amount) external virtual onlyEmergencyAuthorized {
        if (_token == borrowToken) _withdrawBorrowToken(_amount);
        else _withdrawCollateral(_amount);
    }

    // Manually repay debt with loose borrowToken already in the strategy.
    function manualRepayDebt() external virtual onlyEmergencyAuthorized {
        _repayTokenDebt();
    }

}
