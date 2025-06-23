// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.23;

interface IVaultAPROracle {

    function getExpectedApr(address _vault, int256 _delta) external view returns (uint256 apr);
    function getStrategyApr(address _vault, int256 _delta) external view returns (uint256 apr);

}
