// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.24;

interface ICollSurplusPool {

    function getCollateral(
        address _account
    ) external view returns (uint256);

}
