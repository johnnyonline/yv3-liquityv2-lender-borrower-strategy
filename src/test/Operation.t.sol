// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {IVaultAPROracle} from "../interfaces/IVaultAPROracle.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";

contract OperationTest is Setup {

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
        // TODO: add additional check on strat params
    }

    function test_operation(uint256 _amount) public {
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
        assertEq(ERC20(tokenAddrs["WETH"]).balanceOf(strategy.management()), wethBalanceBefore + ETH_GAS_COMPENSATION, "!weth balance");

        checkStrategyTotals(strategy, 0, 0, 0);
    }

    function test_profitableReport_withFees(uint256 _amount) public {
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
        assertEq(ERC20(tokenAddrs["WETH"]).balanceOf(strategy.management()), wethBalanceBefore + ETH_GAS_COMPENSATION, "!weth balance");

        checkStrategyTotals(strategy, 0, 0, 0);
    }

    function test_tendTrigger(uint256 _amount) public {
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

    // function test_operation_overWarningLTV_depositLeversDown // @todo -- here

}
