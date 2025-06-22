// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

interface AggregatorInterface {

    function decimals() external view returns (uint8);
    function latestAnswer() external view returns (int256);

}
