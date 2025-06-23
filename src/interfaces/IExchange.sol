// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

interface IExchange {

    function TOKEN() external view returns (address);
    function PAIRED_WITH() external view returns (address);
    function swap(uint256 amount, uint256 minAmount, bool fromBorrow) external returns (uint256);

}
