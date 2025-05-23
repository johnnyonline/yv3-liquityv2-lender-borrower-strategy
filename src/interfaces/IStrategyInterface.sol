// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {ILenderBorrower} from "./ILenderBorrower.sol";

interface IStrategyInterface is ILenderBorrower {
    // ===============================================================
    // Storage
    // ===============================================================

    function blockWithdrawalsAfterLiquidation() external view returns (bool);
    function troveId() external view returns (uint256);
    function auctionBufferPercentage() external view returns (uint256);
    function minKickAmount() external view returns (uint256);

    // ===============================================================
    // Constants
    // ===============================================================

    function ASSET_TO_BORROW_AUCTION() external view returns (address);
    function BORROW_TO_ASSET_AUCTION() external view returns (address);
    function PRICE_PROVIDER() external view returns (address);
    function BORROWER_OPERATIONS() external view returns (address);
    function TROVE_MANAGER() external view returns (address);

    // ===============================================================
    // Management functions
    // ===============================================================

    function unblockWithdrawalsAfterLiquidation() external;
    function setMinKickAmount(uint256 _minKickAmount) external;
    function setAuctionBufferPercentage(uint256 _auctionBufferPercentage) external;
    function openTrove(uint256 _upperHint, uint256 _lowerHint) external;
    function claimCollateral() external;

    // ===============================================================
    // Emergency authorized functions
    // ===============================================================

    function buyBorrowToken() external;

    // ===============================================================
    // Keeper functions
    // ===============================================================

    function kickRewards() external;
    function adjustZombieTrove(uint256 _upperHint, uint256 _lowerHint) external;
}
