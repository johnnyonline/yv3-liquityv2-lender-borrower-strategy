// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Setup, ITroveManager} from "./utils/Setup.sol";

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

        assertEq(
            ITroveManager(strategy.TROVE_MANAGER()).getLatestTroveData(strategy.troveId()).annualInterestRate,
            MIN_ANNUAL_INTEREST_RATE
        );

        vm.prank(emergencyAdmin);
        strategy.adjustTroveInterestRate(_newAnnualInterestRate, 0, 0);

        assertEq(
            ITroveManager(strategy.TROVE_MANAGER()).getLatestTroveData(strategy.troveId()).annualInterestRate,
            _newAnnualInterestRate
        );
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

    function test_setSurplusFloors(uint256 _minSurplusAbsolute, uint256 _minSurplusRelative) public {
        vm.assume(_minSurplusRelative <= MAX_BPS / 10);
        vm.prank(management);
        strategy.setSurplusFloors(_minSurplusAbsolute, _minSurplusRelative);
        assertEq(strategy.minSurplusAbsolute(), _minSurplusAbsolute);
        assertEq(strategy.minSurplusRelative(), _minSurplusRelative);
    }

    function test_setSurplusFloors_wrongCaller(
        address _wrongCaller
    ) public {
        vm.assume(_wrongCaller != management);
        vm.expectRevert("!management");
        vm.prank(_wrongCaller);
        strategy.setSurplusFloors(0, 0);
    }

    function test_setSurplusFloors_relativeSurplusTooHigh(
        uint256 _minSurplusAbsolute,
        uint256 _minSurplusRelative
    ) public {
        vm.assume(_minSurplusRelative > MAX_BPS / 10);
        vm.prank(management);
        vm.expectRevert("!relativeSurplus");
        strategy.setSurplusFloors(_minSurplusAbsolute, _minSurplusRelative);
    }

    function test_setAllowed(
        address _newAllowed
    ) public {
        assertFalse(strategy.allowed(_newAllowed));
        vm.startPrank(management);
        strategy.setAllowed(_newAllowed, true);
        assertTrue(strategy.allowed(_newAllowed));
        strategy.setAllowed(_newAllowed, false);
        assertFalse(strategy.allowed(_newAllowed));
        vm.stopPrank();
    }

    function setAllowed_wrongCaller(
        address _wrongCaller
    ) public {
        vm.assume(_wrongCaller != management);
        vm.expectRevert("!management");
        vm.prank(_wrongCaller);
        strategy.setAllowed(address(0), true);
    }

    function test_sweep_wrongCaller(
        address _wrongCaller
    ) public {
        vm.assume(_wrongCaller != strategy.GOV());
        vm.expectRevert("!governance");
        vm.prank(_wrongCaller);
        strategy.sweep(address(0));
    }

}
