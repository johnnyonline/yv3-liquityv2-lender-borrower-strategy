// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

interface ICollateralRegistry {

    function redeemCollateral(
        uint256 _boldAmount,
        uint256 _maxIterationsPerCollateral,
        uint256 _maxFeePercentage
    ) external;

}
