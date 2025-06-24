// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {IBaseHealthCheck} from "@periphery/Bases/HealthCheck/IBaseHealthCheck.sol";

interface ILenderBorrower is IBaseHealthCheck {
    // Public Variables
    function borrowToken() external view returns (address);

    function leaveDebtBehind() external view returns (bool);

    function depositLimit() external view returns (uint256);

    function targetLTVMultiplier() external view returns (uint16);

    function warningLTVMultiplier() external view returns (uint16);

    function maxGasPriceToTend() external view returns (uint256);

    function slippage() external view returns (uint256);

    function minAmountToBorrow() external view returns (uint256);

    // External Functions
    function setDepositLimit(uint256 _depositLimit) external;

    function setLtvMultipliers(uint16 _targetLTVMultiplier, uint16 _warningLTVMultiplier) external;

    function setLeaveDebtBehind(bool _leaveDebtBehind) external;

    function setMaxGasPriceToTend(uint256 _maxGasPriceToTend) external;

    function setSlippage(uint256 _slippage) external;

    // Public View Functions
    function getCurrentLTV() external view returns (uint256);

    function getNetBorrowApr(uint256 newAmount) external view returns (uint256);

    function getNetRewardApr(uint256 newAmount) external view returns (uint256);

    function getLiquidateCollateralFactor() external view returns (uint256);

    function balanceOfCollateral() external view returns (uint256);

    function balanceOfDebt() external view returns (uint256);

    function balanceOfLentAssets() external view returns (uint256);

    function balanceOfAsset() external view returns (uint256);

    function balanceOfBorrowToken() external view returns (uint256);

    function borrowTokenOwedBalance() external view returns (uint256);

    // Emergency Functions
    function claimAndSellRewards() external;

    function sellBorrowToken(uint256 _amount) external;

    function manualWithdraw(address _token, uint256 _amount) external;

    function manualRepayDebt() external;
}
