pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20, ITroveManager, IStrategyInterface} from "./utils/Setup.sol";

contract ShutdownTest is Setup {

    function setUp() public virtual override {
        super.setUp();
    }

    function test_shutdownCanWithdraw(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        skip(1 days);

        // Shutdown the strategy
        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Make sure we can still withdraw the full amount
        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");
    }

    function test_emergencyWithdraw_maxUint(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        // Deposit into strategy
        mintAndDepositIntoStrategy(strategy, user, _amount);

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // Earn Interest
        skip(1 days);

        // Shutdown the strategy
        vm.prank(emergencyAdmin);
        strategy.shutdownStrategy();

        assertEq(strategy.totalAssets(), _amount, "!totalAssets");

        // should be able to pass uint 256 max and not revert.
        vm.prank(emergencyAdmin);
        strategy.emergencyWithdraw(type(uint256).max);

        // Make sure we can still withdraw the full amount
        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");
    }

    function test_manualWithdraw_andClose(
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

        // Earn Interest
        simulateEarningInterest();

        uint256 ltv = strategy.getCurrentLTV();

        ERC20 borrowToken = ERC20(strategy.borrowToken());

        assertEq(borrowToken.balanceOf(address(strategy)), 0);
        assertApproxEqAbs(strategy.getCurrentLTV(), ltv, 10);

        uint256 balance = strategy.balanceOfLentAssets();

        vm.expectRevert("!emergency authorized");
        vm.prank(user);
        strategy.manualWithdraw(address(borrowToken), balance);

        vm.prank(management);
        strategy.manualWithdraw(address(borrowToken), balance);

        assertEq(strategy.balanceOfLentAssets(), 0);
        assertEq(borrowToken.balanceOf(address(strategy)), balance);
        assertApproxEqAbs(strategy.getCurrentLTV(), ltv, 10);

        vm.expectRevert("!emergency authorized");
        vm.prank(user);
        strategy.claimAndSellRewards();

        vm.prank(management);
        strategy.claimAndSellRewards();

        vm.expectRevert("!emergency authorized");
        vm.prank(user);
        strategy.manualRepayDebt();

        vm.prank(management);
        strategy.manualRepayDebt();

        assertEq(strategy.balanceOfCollateral(), strategistDeposit + _amount);
        assertEq(strategy.balanceOfLentAssets(), 0);
        assertEq(strategy.balanceOfDebt(), 2_000 ether); // minDebt
        assertEq(borrowToken.balanceOf(address(strategy)), 2_000 ether); // minDebt
        assertLt(strategy.getCurrentLTV(), ltv);

        uint256 wethBalanceBefore = ERC20(tokenAddrs["WETH"]).balanceOf(strategy.management());

        // Shutdown the strategy and close the trove
        vm.startPrank(emergencyAdmin);
        strategy.shutdownStrategy();
        strategy.emergencyWithdraw(type(uint256).max);
        vm.stopPrank();

        assertEq(
            uint8(ITroveManager(strategy.TROVE_MANAGER()).getTroveStatus(strategy.troveId())),
            uint8(ITroveManager.Status.closedByOwner)
        );
        assertEq(strategy.balanceOfCollateral(), 0);
        assertEq(strategy.balanceOfLentAssets(), 0);
        assertEq(strategy.balanceOfDebt(), 0);
        assertEq(borrowToken.balanceOf(address(strategy)), 0);
        assertEq(strategy.getCurrentLTV(), 0);

        uint256 balanceBefore = asset.balanceOf(user);

        // Withdraw all funds
        vm.prank(user);
        strategy.redeem(_amount, user, user);

        assertGe(asset.balanceOf(user), balanceBefore + _amount, "!final balance");

        balanceBefore = asset.balanceOf(strategist);

        // Strategist withdraws all funds
        vm.prank(strategist);
        strategy.redeem(strategistDeposit, strategist, strategist, 0);

        assertGe(asset.balanceOf(strategist), balanceBefore + strategistDeposit, "!final balance");
        assertEq(
            ERC20(tokenAddrs["WETH"]).balanceOf(strategy.management()),
            wethBalanceBefore + ETH_GAS_COMPENSATION,
            "!weth balance"
        );
    }

    function test_sweep(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        ERC20 borrowToken = ERC20(strategy.borrowToken());

        airdrop(asset, address(strategy), _amount);
        airdrop(borrowToken, address(strategy), _amount);

        vm.expectRevert("toopleb");
        vm.prank(user);
        strategy.sweep(address(borrowToken));

        vm.expectRevert("toopleb");
        vm.prank(management);
        strategy.sweep(address(borrowToken));

        address gov = strategy.GOV();

        // Sweep Base token
        uint256 beforeBalance = borrowToken.balanceOf(gov);

        vm.prank(gov);
        strategy.sweep(address(borrowToken));

        assertEq(ERC20(borrowToken).balanceOf(gov), beforeBalance + _amount, "base swept");

        // Cant sweep asset
        vm.expectRevert("!asset");
        vm.prank(gov);
        strategy.sweep(address(asset));
    }

}
