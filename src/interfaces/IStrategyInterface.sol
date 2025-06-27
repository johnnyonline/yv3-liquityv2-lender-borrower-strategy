// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {ILenderBorrower} from "./ILenderBorrower.sol";

interface IStrategyInterface is ILenderBorrower {

    // ===============================================================
    // Storage
    // ===============================================================

    function forceLeverage() external view returns (bool);
    function troveId() external view returns (uint256);
    function dustThreshold() external view returns (uint256);
    function isZombieSlayer(address _zombieSlayer) external view returns (bool);

    // ===============================================================
    // Constants
    // ===============================================================

    function GOV() external view returns (address);
    function VAULT_APR_ORACLE() external view returns (address);
    function PRICE_FEED() external view returns (address);
    function BORROWER_OPERATIONS() external view returns (address);
    function TROVE_MANAGER() external view returns (address);
    function EXCHANGE() external view returns (address);
    function STAKED_LENDER_VAULT() external view returns (address);

    // ===============================================================
    // Privileged functions
    // ===============================================================

    function openTrove(uint256 _upperHint, uint256 _lowerHint) external;
    function adjustTroveInterestRate(uint256 _newAnnualInterestRate, uint256 _upperHint, uint256 _lowerHint) external;
    function buyBorrowToken(uint256 _amount) external;
    function setDustThreshold(
        uint256 _dustThreshold
    ) external;
    function setForceLeverage(
        bool _forceLeverage
    ) external;
    function setZombieSlayer(address _zombieSlayer, bool _isSlayer) external;
    function adjustZombieTrove(uint256 _upperHint, uint256 _lowerHint) external;
    function sweep(
        address _token
    ) external;

    // ===============================================================
    // View functions
    // ===============================================================

    function isRewardsToClaim() external view returns (bool);

}
