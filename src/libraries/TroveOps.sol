// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ITroveManager} from "../interfaces/ITroveManager.sol";
import {ICollSurplusPool} from "../interfaces/ICollSurplusPool.sol";
import {IBorrowerOperations} from "../interfaces/IBorrowerOperations.sol";

library TroveOps {

    using SafeERC20 for IERC20;

    // ===============================================================
    // Constants
    // ===============================================================

    /// @notice Liquity's minimum amount of net Bold debt a trove must have
    ///         If a trove is redeeemed and the debt is less than this, it will be considered a zombie trove
    uint256 public constant MIN_DEBT = 2_000 * 1e18;

    /// @notice Liquity's amount of WETH to be locked in gas pool when opening a trove
    ///         Will be pulled from the contract on `_openTrove`
    uint256 public constant ETH_GAS_COMPENSATION = 0.0375 ether;

    /// @notice Minimum annual interest rate
    uint256 public constant MIN_ANNUAL_INTEREST_RATE = 1e18 / 100 / 2; // 0.5%

    /// @notice WETH token
    IERC20 private constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    // ===============================================================
    // Write functions
    // ===============================================================

    function openTrove(
        IBorrowerOperations _borrowerOperations,
        uint256 _collAmount,
        uint256 _upperHint,
        uint256 _lowerHint
    ) external returns (uint256) {
        WETH.transferFrom(msg.sender, address(this), ETH_GAS_COMPENSATION);
        return _borrowerOperations.openTrove(
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
    }

    function adjustTroveInterestRate(
        IBorrowerOperations _borrowerOperations,
        uint256 _troveId,
        uint256 _newAnnualInterestRate,
        uint256 _upperHint,
        uint256 _lowerHint
    ) external {
        _borrowerOperations.adjustTroveInterestRate(
            _troveId,
            _newAnnualInterestRate,
            _upperHint,
            _lowerHint,
            type(uint256).max // maxUpfrontFee
        );
    }

    function adjustZombieTrove(
        IBorrowerOperations _borrowerOperations,
        uint256 _troveId,
        uint256 _balanceOfAsset,
        uint256 _balanceOfDebt,
        uint256 _upperHint,
        uint256 _lowerHint
    ) external {
        _borrowerOperations.adjustZombieTrove(
            _troveId,
            _balanceOfAsset, // collChange
            true, // isCollIncrease
            MIN_DEBT - _balanceOfDebt, // boldChange
            true, // isDebtIncrease
            _upperHint,
            _lowerHint,
            type(uint256).max // maxUpfrontFee
        );
    }

    function onEmergencyWithdraw(
        ITroveManager _troveManager,
        IBorrowerOperations _borrowerOperations,
        ICollSurplusPool _collSurplusPool,
        address _management,
        uint256 _troveId
    ) external {
        if (_troveManager.getTroveStatus(_troveId) == ITroveManager.Status.active) {
            _borrowerOperations.closeTrove(_troveId);
            uint256 _balance = WETH.balanceOf(address(this));
            if (_balance > ETH_GAS_COMPENSATION) WETH.safeTransfer(_management, ETH_GAS_COMPENSATION);
        } else if (_troveManager.getTroveStatus(_troveId) == ITroveManager.Status.closedByLiquidation) {
            if (_collSurplusPool.getCollateral(address(this)) > 0) _borrowerOperations.claimCollateral();
        }
    }

}
