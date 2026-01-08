// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.24;

interface IBorrowerOperations {

    function getEntireBranchColl() external view returns (uint256 entireSystemColl);
    function getEntireBranchDebt() external view returns (uint256 entireSystemDebt);
    function MCR() external view returns (uint256);
    function CCR() external view returns (uint256);
    function openTrove(
        address _owner,
        uint256 _ownerIndex,
        uint256 _collAmount,
        uint256 _boldAmount,
        uint256 _upperHint,
        uint256 _lowerHint,
        uint256 _annualInterestRate,
        uint256 _maxUpfrontFee,
        address _addManager,
        address _removeManager,
        address _receiver
    ) external returns (uint256);
    function addColl(
        uint256 _troveId,
        uint256 _collAmount
    ) external;
    function withdrawColl(
        uint256 _troveId,
        uint256 _amount
    ) external;
    function repayBold(
        uint256 _troveId,
        uint256 _boldAmount
    ) external;
    function withdrawBold(
        uint256 _troveId,
        uint256 _amount,
        uint256 _maxFee
    ) external;
    function closeTrove(
        uint256 _troveId
    ) external;
    function claimCollateral() external;
    function adjustZombieTrove(
        uint256 _troveId,
        uint256 _collChange,
        bool _isCollIncrease,
        uint256 _boldChange,
        bool _isDebtIncrease,
        uint256 _upperHint,
        uint256 _lowerHint,
        uint256 _maxUpfrontFee
    ) external;
    function adjustTroveInterestRate(
        uint256 _troveId,
        uint256 _newAnnualInterestRate,
        uint256 _upperHint,
        uint256 _lowerHint,
        uint256 _maxUpfrontFee
    ) external;

}
