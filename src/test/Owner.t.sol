// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ERC20, IStrategyInterface} from "./utils/Setup.sol";

contract OwnerTest is Setup {

    function setUp() public virtual override {
        super.setUp();
    }

    function test_openTrove_wrongCaller(
        address _wrongCaller
    ) public {
        vm.assume(_wrongCaller != emergencyAdmin);
        vm.expectRevert("!emergency authorized");
        strategy.openTrove(0, 0);
    }

    function test_adjustTroveInterestRate() public {
        strategistDepositAndOpenTrove(true);

        uint256 _newAnnualInterestRate = MIN_ANNUAL_INTEREST_RATE * 2;

        vm.prank(management);
        strategy.setForceLeverage(false);

        assertEq(strategy.getNetBorrowApr(0), MIN_ANNUAL_INTEREST_RATE);

        vm.prank(emergencyAdmin);
        strategy.adjustTroveInterestRate(_newAnnualInterestRate, 0, 0);

        assertEq(strategy.getNetBorrowApr(0), _newAnnualInterestRate);
    }

    function test_adjustTroveInterestRate_noTrove() public {
        vm.prank(emergencyAdmin);
        vm.expectRevert("ERC721: invalid token ID");
        strategy.adjustTroveInterestRate(MIN_ANNUAL_INTEREST_RATE, 0, 0);
    }

    function test_adjustTroveInterestRate_wrongCaller(
        address _wrongCaller
    ) public {
        vm.assume(_wrongCaller != emergencyAdmin);
        vm.expectRevert("!emergency authorized");
        strategy.adjustTroveInterestRate(0, 0, 0);
    }

    function test_buyBorrowToken_wrongCaller(
        address _wrongCaller
    ) public {
        vm.assume(_wrongCaller != emergencyAdmin);
        vm.expectRevert("!emergency authorized");
        strategy.buyBorrowToken(0);
    }

    function test_setDustThreshold(
        uint256 _newDustThreshold
    ) public {
        vm.prank(management);
        strategy.setDustThreshold(_newDustThreshold);
        assertEq(strategy.dustThreshold(), _newDustThreshold);
    }

    function test_setDustThreshold_wrongCaller(
        address _wrongCaller
    ) public {
        vm.assume(_wrongCaller != management);
        vm.expectRevert("!management");
        vm.prank(_wrongCaller);
        strategy.setDustThreshold(0);
    }

    function test_setForceLeverage() public {
        assertTrue(strategy.forceLeverage());
        vm.prank(management);
        strategy.setForceLeverage(false);
        assertFalse(strategy.forceLeverage());
    }

    function test_setForceLeverage_wrongCaller(
        address _wrongCaller
    ) public {
        vm.assume(_wrongCaller != management);
        vm.expectRevert("!management");
        vm.prank(_wrongCaller);
        strategy.setForceLeverage(false);
    }

    function test_setZombieSlayer() public {
        address _zombieSlayer = address(0x123);
        assertFalse(strategy.isZombieSlayer(_zombieSlayer));
        vm.prank(management);
        strategy.setZombieSlayer(_zombieSlayer, true);
        assertTrue(strategy.isZombieSlayer(_zombieSlayer));
    }

    function test_setZombieSlayer_wrongCaller(
        address _wrongCaller
    ) public {
        vm.assume(_wrongCaller != management);
        vm.expectRevert("!management");
        vm.prank(_wrongCaller);
        strategy.setZombieSlayer(address(0x123), true);
    }

    function test_adjustZombieTrove_wrongCaller(
        address _wrongCaller
    ) public {
        vm.expectRevert("!zombieSlayer");
        vm.prank(_wrongCaller);
        strategy.adjustZombieTrove(0, 0);
    }

    function test_sweep_wrongCaller(
        address _wrongCaller
    ) public {
        vm.assume(_wrongCaller != strategy.GOV());
        vm.expectRevert("toopleb");
        vm.prank(_wrongCaller);
        strategy.sweep(address(0));
    }

}
