// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {IVaultAPROracle} from "../interfaces/IVaultAPROracle.sol";
import {
    AggregatorInterface,
    Setup,
    ERC20,
    IAddressesRegistry,
    IExchange,
    IStrategy,
    IStrategyInterface
} from "./utils/Setup.sol";

contract OperationTest is Setup {

    error NotEnoughBoldBalance();

    function setUp() public virtual override {
        super.setUp();
    }

    function test_setupStrategyOK() public {
        console2.log("address of strategy", address(strategy));
        assertTrue(address(0) != address(strategy));
        assertEq(strategy.asset(), address(asset));
        assertEq(strategy.management(), management);
        assertEq(strategy.performanceFeeRecipient(), performanceFeeRecipient);
        assertEq(strategy.keeper(), keeper);
        assertEq(strategy.borrowToken(), IStrategyInterface(strategy.lenderVault()).asset());
        assertTrue(strategy.forceLeverage());
        assertEq(strategy.troveId(), 0);
        assertEq(strategy.dustThreshold(), strategy.MIN_DUST_THRESHOLD());
        assertEq(strategy.BORROWER_OPERATIONS(), borrowerOperations);
        assertEq(strategy.TROVE_MANAGER(), troveManager);
        assertEq(strategy.EXCHANGE(), address(exchange));
        assertEq(strategy.STAKED_LENDER_VAULT(), stybold);
    }

    function test_invalidDeployment() public {
        vm.expectRevert("!exchange");
        strategyFactory.newStrategy(
            IAddressesRegistry(wrongAddressesRegistry),
            IStrategy(address(lenderVault)),
            AggregatorInterface(address(0)),
            IExchange(address(exchange)),
            "Tokenized Strategy"
        );

        vm.expectRevert();
        strategyFactory.newStrategy(
            IAddressesRegistry(addressesRegistry),
            IStrategy(tokenAddrs["YFI"]),
            AggregatorInterface(address(0)),
            IExchange(address(exchange)),
            "Tokenized Strategy"
        );

        vm.expectRevert("!priceFeed");
        strategyFactory.newStrategy(
            IAddressesRegistry(addressesRegistry),
            IStrategy(address(lenderVault)),
            AggregatorInterface(address(tokenAddrs["YFI"])),
            IExchange(address(exchange)),
            "Tokenized Strategy"
        );

        vm.expectRevert();
        strategyFactory.newStrategy(
            IAddressesRegistry(addressesRegistry),
            IStrategy(address(lenderVault)),
            AggregatorInterface(address(0)),
            IExchange(address(0)),
            "Tokenized Strategy"
        );
    }

    function test_operation(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Set protocol fee to 0 and perf fee to 0
        setFees(0, 0);

        // Strategist makes initial deposit and opens a trove
        uint256 strategistDeposit = strategistDepositAndOpenTrove(true);

        assertEq(strategy.totalAssets(), strategistDeposit, "!strategistTotalAssets");

        uint256 targetLTV = (strategy.getLiquidateCollateralFactor() * strategy.targetLTVMultiplier()) / MAX_BPS;

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount + strategistDeposit, _amount + strategistDeposit, 0);
        assertEq(strategy.totalAssets(), _amount + strategistDeposit, "!totalAssets");
        assertApproxEqRel(strategy.getCurrentLTV(), targetLTV, 1e15); // 0.1%
        assertApproxEqAbs(strategy.balanceOfCollateral(), _amount + strategistDeposit, 3, "!balanceOfCollateral");
        assertApproxEqRel(strategy.balanceOfDebt(), strategy.balanceOfLentAssets(), 1e15); // 0.1%

        // Earn Interest
        simulateEarningInterest();

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGt(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");

        balanceBefore = asset.balanceOf(strategist);
        uint256 wethBalanceBefore = ERC20(tokenAddrs["WETH"]).balanceOf(strategy.management());

        // Earn a bit
        simulateEarningInterest();

        // Shutdown the strategy (can't repay entire debt without)
        vm.startPrank(emergencyAdmin);
        strategy.shutdownStrategy();
        strategy.emergencyWithdraw(type(uint256).max);
        vm.stopPrank();

        skip(strategy.profitMaxUnlockTime());

        // Strategist withdraws all funds
        vm.prank(strategist);
        strategy.redeem(strategistDeposit, strategist, strategist, 0);

        assertGt(asset.balanceOf(strategist), balanceBefore + strategistDeposit, "!final balance");
        assertEq(
            ERC20(tokenAddrs["WETH"]).balanceOf(strategy.management()),
            wethBalanceBefore + ETH_GAS_COMPENSATION,
            "!weth balance"
        );

        checkStrategyTotals(strategy, 0, 0, 0);
    }

    function test_profitableReport_withFees(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Set protocol fee to 0 and perf fee to 10%
        setFees(0, 1_000);

        // Strategist makes initial deposit and opens a trove
        uint256 strategistDeposit = strategistDepositAndOpenTrove(true);

        assertEq(strategy.totalAssets(), strategistDeposit, "!strategistTotalAssets");

        uint256 targetLTV = (strategy.getLiquidateCollateralFactor() * strategy.targetLTVMultiplier()) / MAX_BPS;

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount + strategistDeposit, _amount + strategistDeposit, 0);
        assertEq(strategy.totalAssets(), _amount + strategistDeposit, "!totalAssets");
        assertApproxEqRel(strategy.getCurrentLTV(), targetLTV, 1e15); // 0.1%
        assertApproxEqAbs(strategy.balanceOfCollateral(), _amount + strategistDeposit, 3, "!balanceOfCollateral");
        assertApproxEqRel(strategy.balanceOfDebt(), strategy.balanceOfLentAssets(), 1e15); // 0.1%

        // Earn Interest
        simulateEarningInterest();

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGt(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");

        // Get the expected fee
        uint256 expectedShares = (profit * 1_000) / MAX_BPS;

        assertEq(strategy.balanceOf(performanceFeeRecipient), expectedShares);

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");

        vm.prank(performanceFeeRecipient);
        strategy.redeem(expectedShares, performanceFeeRecipient, performanceFeeRecipient);

        assertGe(asset.balanceOf(performanceFeeRecipient), expectedShares, "!perf fee out");

        // balanceBefore = asset.balanceOf(strategist);
        uint256 wethBalanceBefore = ERC20(tokenAddrs["WETH"]).balanceOf(strategy.management());

        // Earn Interest
        simulateEarningInterest();

        // Shutdown the strategy (can't repay entire debt without)
        vm.startPrank(emergencyAdmin);
        strategy.shutdownStrategy();
        strategy.emergencyWithdraw(type(uint256).max);
        vm.stopPrank();

        skip(strategy.profitMaxUnlockTime());

        // Strategist withdraws all funds
        vm.prank(strategist);
        strategy.redeem(strategistDeposit, strategist, strategist, 0);

        assertGt(asset.balanceOf(strategist), balanceBefore + strategistDeposit, "!final balance");
        assertEq(
            ERC20(tokenAddrs["WETH"]).balanceOf(strategy.management()),
            wethBalanceBefore + ETH_GAS_COMPENSATION,
            "!weth balance"
        );

        checkStrategyTotals(strategy, 0, 0, 0);
    }

    function test_operation_overWarningLTV_depositLeversDown(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Strategist makes initial deposit and opens a trove
        uint256 strategistDeposit = strategistDepositAndOpenTrove(true);

        uint256 targetLTV = (strategy.getLiquidateCollateralFactor() * strategy.targetLTVMultiplier()) / MAX_BPS;

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount + strategistDeposit, _amount + strategistDeposit, 0);
        assertEq(strategy.totalAssets(), _amount + strategistDeposit, "!totalAssets");
        assertApproxEqRel(strategy.getCurrentLTV(), targetLTV, 1e15); // 0.1%
        assertApproxEqAbs(strategy.balanceOfCollateral(), _amount + strategistDeposit, 3, "!balanceOfCollateral");
        assertApproxEqRel(strategy.balanceOfDebt(), strategy.balanceOfLentAssets(), 1e15); // 0.1%

        // Withdrawl some collateral to pump LTV
        uint256 collToSell = strategy.balanceOfCollateral() * 20 / 100;
        vm.prank(emergencyAdmin);
        strategy.manualWithdraw(address(0), collToSell);

        uint256 warningLTV = (strategy.getLiquidateCollateralFactor() * strategy.warningLTVMultiplier()) / MAX_BPS;

        assertGt(strategy.getCurrentLTV(), warningLTV);
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertApproxEqRel(strategy.getCurrentLTV(), targetLTV, 1e15); // 0.1%
    }

    function test_tendTrigger(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // No assets should be false
        (bool trigger,) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Strategist makes initial deposit and opens a trove
        strategistDepositAndOpenTrove(true);

        uint256 targetLTV = (strategy.getLiquidateCollateralFactor() * strategy.targetLTVMultiplier()) / MAX_BPS;

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        (trigger,) = strategy.tendTrigger();
        assertFalse(trigger);

        // Withdrawl some collateral to pump LTV
        uint256 collToSell = strategy.balanceOfCollateral() * 20 / 100;
        vm.prank(emergencyAdmin);
        strategy.manualWithdraw(address(0), collToSell);

        (trigger,) = strategy.tendTrigger();
        assertTrue(trigger, "warning ltv");

        // Even with a 0 for max Tend Base Fee its true
        vm.prank(management);
        strategy.setMaxGasPriceToTend(0);

        (trigger,) = strategy.tendTrigger();
        assertTrue(trigger, "warning ltv 2");

        // Get max gas price back to normal
        vm.prank(management);
        strategy.setMaxGasPriceToTend(200e9);

        vm.prank(keeper);
        strategy.tend();

        (trigger,) = strategy.tendTrigger();
        assertTrue(!trigger, "post tend");

        // Earn Interest
        simulateEarningInterest();

        vm.prank(keeper);
        strategy.report();

        // Lower LTV
        uint256 borrowed = strategy.balanceOfDebt();
        airdrop(ERC20(strategy.borrowToken()), address(strategy), borrowed / 2);

        vm.prank(management);
        strategy.manualRepayDebt();

        assertLt(strategy.getCurrentLTV(), targetLTV);

        (trigger,) = strategy.tendTrigger();
        assertTrue(trigger);

        vm.prank(keeper);
        strategy.tend();

        (trigger,) = strategy.tendTrigger();
        assertTrue(!trigger);

        // Drop reported price of collateral so we can get liquidated
        dropCollateralPrice();

        (trigger,) = strategy.tendTrigger();
        assertTrue(trigger);

        vm.prank(keeper);
        strategy.tend();

        (trigger,) = strategy.tendTrigger();
        assertTrue(!trigger);
    }

    function test_tendTrigger_noRewards(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Strategist makes initial deposit and opens a trove
        strategistDepositAndOpenTrove(true);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        (bool trigger,) = strategy.tendTrigger();
        assertTrue(!trigger);

        // (almost) zero out rewards
        vm.mockCall(
            address(strategy.VAULT_APR_ORACLE()),
            abi.encodeWithSelector(IVaultAPROracle.getStrategyApr.selector),
            abi.encode(1)
        );
        assertEq(strategy.getNetRewardApr(0), 1);

        vm.prank(management);
        strategy.setForceLeverage(false);

        // Now that it's unprofitable to borrow, we should tend
        (trigger,) = strategy.tendTrigger();
        assertTrue(trigger);

        vm.prank(management);
        strategy.setForceLeverage(true);

        assertTrue(strategy.forceLeverage());
        assertEq(strategy.getNetBorrowApr(0), 0);

        // Now that we force leverage, we should not tend
        (trigger,) = strategy.tendTrigger();
        assertTrue(!trigger);

        vm.expectRevert("!management");
        strategy.setForceLeverage(false);
    }

    function test_operation_redemptionToZombie(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Strategist makes initial deposit and opens a trove
        uint256 strategistDeposit = strategistDepositAndOpenTrove(true);

        uint256 targetLTV = (strategy.getLiquidateCollateralFactor() * strategy.targetLTVMultiplier()) / MAX_BPS;

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount + strategistDeposit, _amount + strategistDeposit, 0);
        assertEq(strategy.totalAssets(), _amount + strategistDeposit, "!totalAssets");
        assertApproxEqRel(strategy.getCurrentLTV(), targetLTV, 1e15); // 0.1%
        assertApproxEqAbs(strategy.balanceOfCollateral(), _amount + strategistDeposit, 3, "!balanceOfCollateral");
        assertApproxEqRel(strategy.balanceOfDebt(), strategy.balanceOfLentAssets(), 1e15); // 0.1%

        uint256 debtBefore = strategy.balanceOfDebt();

        // Simulate a redemption that leads to a zombie trove
        simulateCollateralRedemption(strategy.balanceOfDebt() * 10, true);

        // Check debt decreased
        assertLt(strategy.balanceOfDebt(), debtBefore, "!debt");
        assertLt(strategy.getCurrentLTV(), targetLTV, "!ltv");

        // Rewards to claim
        assertTrue(strategy.isRewardsToClaim(), "!rewardsToClaim");

        // Rewards to sell
        (bool trigger,) = strategy.tendTrigger();
        assertTrue(trigger, "sellRewards");

        // Sell the rewards
        vm.prank(keeper);
        strategy.tend();

        // We sold the rewards
        (trigger,) = strategy.tendTrigger();
        assertFalse(trigger, "!sellRewards");

        // Report profit (doesn't leverage)
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGt(profit, 0, "!profit"); // If no price swinges / other costs, being redeemed is actually profitable
        assertEq(loss, 0, "!loss");
        assertLt(strategy.getCurrentLTV(), targetLTV, "!ltv");

        // Set keeper as zombie slayer
        vm.prank(management);
        strategy.setZombieSlayer(keeper, true);

        // Get our trove out from zombie mode
        (uint256 _upperHint, uint256 _lowerHint) = findHints();
        vm.prank(keeper);
        strategy.adjustZombieTrove(_upperHint, _lowerHint);

        vm.prank(keeper);
        vm.expectRevert("!zombie");
        strategy.adjustZombieTrove(_upperHint, _lowerHint);

        // Now need to leverage
        (trigger,) = strategy.tendTrigger();
        assertTrue(trigger, "leverage");

        // Leverage up
        vm.prank(keeper);
        strategy.tend();

        assertApproxEqRel(strategy.getCurrentLTV(), targetLTV, 1e15); // 0.1%

        // Earn Interest
        simulateEarningInterest();

        // Report profit
        vm.prank(keeper);
        (profit, loss) = strategy.report();

        // Check return Values
        assertGt(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");
    }

    function test_operation_redemptionNoZombie(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Strategist makes initial deposit and opens a trove
        uint256 strategistDeposit = strategistDepositAndOpenTrove(true);

        assertEq(strategy.totalAssets(), strategistDeposit, "!strategistTotalAssets");

        uint256 targetLTV = (strategy.getLiquidateCollateralFactor() * strategy.targetLTVMultiplier()) / MAX_BPS;

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount + strategistDeposit, _amount + strategistDeposit, 0);
        assertEq(strategy.totalAssets(), _amount + strategistDeposit, "!totalAssets");
        assertApproxEqRel(strategy.getCurrentLTV(), targetLTV, 1e15); // 0.1%
        assertApproxEqAbs(strategy.balanceOfCollateral(), _amount + strategistDeposit, 3, "!balanceOfCollateral");
        assertApproxEqRel(strategy.balanceOfDebt(), strategy.balanceOfLentAssets(), 1e15); // 0.1%

        uint256 debtBefore = strategy.balanceOfDebt();

        // Simulate a redemption that doesnt lead to a zombie trove
        simulateCollateralRedemption(strategy.balanceOfDebt() / 10, false);

        // Check debt decreased
        assertLt(strategy.balanceOfDebt(), debtBefore, "!debt");

        // Rewards to claim
        assertTrue(strategy.isRewardsToClaim(), "!rewardsToClaim");

        // Rewards to sell
        (bool trigger,) = strategy.tendTrigger();
        assertTrue(trigger, "sellRewards");

        // Sell the rewards
        vm.prank(keeper);
        strategy.tend();

        // We sold the rewards
        (trigger,) = strategy.tendTrigger();
        assertFalse(trigger, "!sellRewards");

        assertApproxEqRel(strategy.getCurrentLTV(), targetLTV, 1e15); // 0.1%

        // Earn Interest
        simulateEarningInterest();

        // Report profit
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertGt(profit, 0, "!profit");
        assertEq(loss, 0, "!loss");
    }

    function test_operation_redemption_withLoss(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Strategist makes initial deposit and opens a trove
        uint256 strategistDeposit = strategistDepositAndOpenTrove(true);

        assertEq(strategy.totalAssets(), strategistDeposit, "!strategistTotalAssets");

        uint256 targetLTV = (strategy.getLiquidateCollateralFactor() * strategy.targetLTVMultiplier()) / MAX_BPS;

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount + strategistDeposit, _amount + strategistDeposit, 0);
        assertEq(strategy.totalAssets(), _amount + strategistDeposit, "!totalAssets");
        assertApproxEqRel(strategy.getCurrentLTV(), targetLTV, 1e15); // 0.1%
        assertApproxEqAbs(strategy.balanceOfCollateral(), _amount + strategistDeposit, 3, "!balanceOfCollateral");
        assertApproxEqRel(strategy.balanceOfDebt(), strategy.balanceOfLentAssets(), 1e15); // 0.1%

        uint256 debtBefore = strategy.balanceOfDebt();

        // Simulate a redemption that doesnt lead to a zombie trove
        simulateCollateralRedemption(strategy.balanceOfDebt() / 10, false);

        // Check debt decreased
        assertLt(strategy.balanceOfDebt(), debtBefore, "!debt");

        // Rewards to claim
        assertTrue(strategy.isRewardsToClaim(), "!rewardsToClaim");

        // Rewards to sell
        (bool trigger,) = strategy.tendTrigger();
        assertTrue(trigger, "sellRewards");

        // Get rid of some borrow token to simulate a loss
        vm.startPrank(address(strategy));
        ERC20(strategy.borrowToken()).transfer(
            address(6969), ERC20(strategy.borrowToken()).balanceOf(address(strategy)) * 90 / 100
        );
        vm.stopPrank();

        // Sell the rewards
        vm.prank(keeper);
        strategy.tend();

        // We sold the rewards
        (trigger,) = strategy.tendTrigger();
        assertFalse(trigger, "!sellRewards");

        assertApproxEqRel(strategy.getCurrentLTV(), targetLTV, 1e15); // 0.1%

        // Set health check to accept loss
        vm.prank(management);
        strategy.setLossLimitRatio(5_000); // 50% loss

        // Report loss
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertEq(profit, 0, "!profit");
        assertGt(loss, 0, "!loss");
    }

    function test_operation_lostLentAssets(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Set protocol fee to 0 and perf fee to 0
        setFees(0, 0);

        // Strategist makes initial deposit and opens a trove
        uint256 strategistDeposit = strategistDepositAndOpenTrove(true);

        assertEq(strategy.totalAssets(), strategistDeposit, "!strategistTotalAssets");

        uint256 targetLTV = (strategy.getLiquidateCollateralFactor() * strategy.targetLTVMultiplier()) / MAX_BPS;

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount + strategistDeposit, _amount + strategistDeposit, 0);
        assertEq(strategy.totalAssets(), _amount + strategistDeposit, "!totalAssets");
        assertApproxEqRel(strategy.getCurrentLTV(), targetLTV, 1e15); // 0.1%
        assertApproxEqAbs(strategy.balanceOfCollateral(), _amount + strategistDeposit, 3, "!balanceOfCollateral");
        assertApproxEqRel(strategy.balanceOfDebt(), strategy.balanceOfLentAssets(), 1e15); // 0.1%

        uint256 vaultLoss = strategy.balanceOfLentAssets() * 5 / 100; // 5% loss
        vm.prank(address(strategy));
        ERC20(address(lenderVault)).transfer(address(6969), vaultLoss);

        // Set health check to accept loss
        vm.prank(management);
        strategy.setLossLimitRatio(5_000); // 50% loss

        // Report loss
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertEq(profit, 0, "!profit");
        assertGe(loss, 0, "!loss");

        // Shutdown the strategy (can't repay entire debt without)
        vm.startPrank(emergencyAdmin);
        strategy.shutdownStrategy();

        vm.expectRevert(NotEnoughBoldBalance.selector); // Not enough BOLD to repay the loan
        strategy.emergencyWithdraw(type(uint256).max);

        // Withdraw enough collateral to repay the loan
        uint256 collToSell = strategy.balanceOfCollateral() * 25 / 100;
        strategy.manualWithdraw(address(0), collToSell);

        // Sell collateral to buy debt
        strategy.buyBorrowToken(type(uint256).max);

        // Close trove and repay the loan
        strategy.emergencyWithdraw(type(uint256).max);

        // Sell any leftover borrow token to asset
        strategy.sellBorrowToken(type(uint256).max);

        vm.stopPrank();

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertLt(asset.balanceOf(user), balanceBefore + _amount, "!final balance");

        // Around 5% loss
        assertApproxEqRel(asset.balanceOf(user), balanceBefore + _amount, 5e16); // 5%

        balanceBefore = asset.balanceOf(strategist);

        // Report
        vm.prank(keeper);
        strategy.report();

        vm.startPrank(strategist);
        strategy.redeem(strategy.maxRedeem(strategist), strategist, strategist);
        vm.stopPrank();

        assertLt(asset.balanceOf(strategist), balanceBefore + strategistDeposit, "!final balance");

        // Around 5% loss
        assertApproxEqRel(asset.balanceOf(strategist), balanceBefore + strategistDeposit, 6e16); // 6% :O

        checkStrategyTotals(strategy, 0, 0, 0);
    }

    function test_operation_liquidation(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Strategist makes initial deposit and opens a trove
        uint256 strategistDeposit = strategistDepositAndOpenTrove(true);

        assertEq(strategy.totalAssets(), strategistDeposit, "!strategistTotalAssets");

        uint256 targetLTV = (strategy.getLiquidateCollateralFactor() * strategy.targetLTVMultiplier()) / MAX_BPS;

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        checkStrategyTotals(strategy, _amount + strategistDeposit, _amount + strategistDeposit, 0);
        assertEq(strategy.totalAssets(), _amount + strategistDeposit, "!totalAssets");
        assertApproxEqRel(strategy.getCurrentLTV(), targetLTV, 1e15); // 0.1%
        assertApproxEqAbs(strategy.balanceOfCollateral(), _amount + strategistDeposit, 3, "!balanceOfCollateral");
        assertApproxEqRel(strategy.balanceOfDebt(), strategy.balanceOfLentAssets(), 1e15); // 0.1%

        // Simulate a liquidation
        simulateLiquidation();

        // Check position
        assertEq(strategy.balanceOfDebt(), 0, "!debt");
        assertEq(strategy.balanceOfCollateral(), 0, "!collateral");

        // Sell all borrow token
        (bool trigger,) = strategy.tendTrigger();
        assertTrue(trigger, "sellRewards");

        // Sell the rewards
        vm.prank(keeper);
        strategy.tend();

        // We sold the borrow token
        (trigger,) = strategy.tendTrigger();
        assertFalse(trigger, "!sellRewards");

        // Set health check to accept loss
        vm.prank(management);
        strategy.setLossLimitRatio(5_000); // 50% loss

        // Report loss
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        // Check return Values
        assertEq(profit, 0, "!profit");
        assertGt(loss, 0, "!loss");

        // Shutdown the strategy
        vm.startPrank(emergencyAdmin);
        strategy.shutdownStrategy();
        strategy.emergencyWithdraw(type(uint256).max);
        vm.stopPrank();

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        // Strategist withdraws all funds
        vm.prank(strategist);
        strategy.redeem(strategistDeposit, strategist, strategist, 0);

        checkStrategyTotals(strategy, 0, 0, 0);
    }

}
