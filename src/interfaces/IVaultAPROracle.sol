// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

interface IVaultAPROracle {

    function getExpectedApr(
        address _vault,
        int256 _delta
    ) external view returns (uint256 apr);
    function getStrategyApr(
        address _vault,
        int256 _delta
    ) external view returns (uint256 apr);
    function setOracle(
        address _strategy,
        address _oracle
    ) external;

}
