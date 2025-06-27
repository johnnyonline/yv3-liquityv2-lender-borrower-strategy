// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20} from "./utils/Setup.sol";

contract ExchangeTest is Setup {

    function setUp() public virtual override {
        super.setUp();

        minFuzzAmount = 1e16; // 0.01 BOLD
    }

    function test_setupOK() public {
        assertEq(exchange.TOKEN(), strategy.borrowToken());
        assertEq(exchange.PAIRED_WITH(), strategy.asset());
    }

    function test_swapFrom(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        airdrop(ERC20(exchange.TOKEN()), user, _amount);

        uint256 _balanceBeforeToken = ERC20(exchange.TOKEN()).balanceOf(user);
        uint256 _balanceBeforePairedWith = ERC20(exchange.PAIRED_WITH()).balanceOf(user);

        vm.startPrank(user);
        ERC20(exchange.TOKEN()).approve(address(exchange), _amount);
        vm.expectRevert("slippage rekt you");
        exchange.swap(_amount, type(uint256).max, true);
        uint256 _amountOut = exchange.swap(_amount, 0, true);
        vm.stopPrank();

        // Check user balances
        assertEq(ERC20(exchange.TOKEN()).balanceOf(user), _balanceBeforeToken - _amount);
        assertEq(ERC20(exchange.PAIRED_WITH()).balanceOf(user), _balanceBeforePairedWith + _amountOut);

        // Check zapper balances
        assertEq(ERC20(exchange.TOKEN()).balanceOf(address(exchange)), 0);
        assertEq(ERC20(exchange.PAIRED_WITH()).balanceOf(address(exchange)), 0);
    }

    function test_swapTo(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        airdrop(ERC20(exchange.PAIRED_WITH()), user, _amount);

        uint256 _balanceBeforeToken = ERC20(exchange.TOKEN()).balanceOf(user);
        uint256 _balanceBeforePairedWith = ERC20(exchange.PAIRED_WITH()).balanceOf(user);

        vm.startPrank(user);
        ERC20(exchange.PAIRED_WITH()).approve(address(exchange), _amount);
        vm.expectRevert("slippage rekt you");
        exchange.swap(_amount, type(uint256).max, false);
        uint256 _amountOut = exchange.swap(_amount, 0, false);
        vm.stopPrank();

        // Check user balances
        assertEq(ERC20(exchange.PAIRED_WITH()).balanceOf(user), _balanceBeforePairedWith - _amount);
        assertEq(ERC20(exchange.TOKEN()).balanceOf(user), _balanceBeforeToken + _amountOut);

        // Check zapper balances
        assertEq(ERC20(exchange.TOKEN()).balanceOf(address(exchange)), 0);
        assertEq(ERC20(exchange.PAIRED_WITH()).balanceOf(address(exchange)), 0);
    }

    function test_sweep(
        uint256 _amount
    ) public {
        vm.assume(_amount > minFuzzAmount && _amount < maxFuzzAmount);

        airdrop(ERC20(exchange.TOKEN()), address(exchange), _amount);
        uint256 _balanceBefore = ERC20(exchange.TOKEN()).balanceOf(exchange.SMS());

        vm.startPrank(exchange.SMS());
        exchange.sweep(ERC20(exchange.TOKEN()));

        vm.expectRevert("!balance");
        exchange.sweep(ERC20(tokenAddrs["YFI"]));

        vm.stopPrank();

        assertEq(ERC20(exchange.TOKEN()).balanceOf(exchange.SMS()), _balanceBefore + _amount);
        assertEq(ERC20(exchange.TOKEN()).balanceOf(address(exchange)), 0);
    }

    function test_sweep_wrongCaller(
        address _wrongCaller
    ) public {
        vm.assume(_wrongCaller != exchange.SMS());

        ERC20 token = ERC20(exchange.TOKEN());

        airdrop(token, address(exchange), 1e18);

        vm.expectRevert("!caller");
        vm.prank(_wrongCaller);
        exchange.sweep(token);
    }

}
