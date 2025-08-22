// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IExchange {

    function SMS() external view returns (address);
    function BORROW() external view returns (address);
    function COLLATERAL() external view returns (address);
    function swap(uint256 _amount, uint256 _minAmount, bool _fromBorrow) external returns (uint256);
    function sweep(
        IERC20 _token
    ) external;

}
