// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.24;

import {ILenderBorrower} from "./ILenderBorrower.sol";

interface IStrategyInterface is ILenderBorrower {

    // ===============================================================
    // Storage
    // ===============================================================

    function troveId() external view returns (uint256);
    function minSurplusAbsolute() external view returns (uint256);
    function minSurplusRelative() external view returns (uint256);
    function allowed(
        address _address
    ) external view returns (bool);

    // ===============================================================
    // Constants
    // ===============================================================

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
    function buyBorrowToken(
        uint256 _amount
    ) external;
    function adjustZombieTrove(uint256 _upperHint, uint256 _lowerHint) external;
    function setSurplusFloors(uint256 _minSurplusAbsolute, uint256 _minSurplusRelative) external;
    function setAllowed(address _address, bool _allowed) external;
    function sweep(
        address _token
    ) external;

    // ===============================================================
    // View functions
    // ===============================================================

    function hasBorrowTokenSurplus() external view returns (bool);

}
