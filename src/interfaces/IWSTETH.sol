// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

interface IWSTETH {

    function decimals() external view returns (uint8);
    function stEthPerToken() external view returns (uint256);

}
