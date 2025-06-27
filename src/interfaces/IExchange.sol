// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IExchange {

    function SMS() external view returns (address);
    function TOKEN() external view returns (address);
    function PAIRED_WITH() external view returns (address);
    function swap(uint256 amount, uint256 minAmount, bool fromBorrow) external returns (uint256);
    function sweep(IERC20 _token) external;

}
