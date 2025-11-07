// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.24;

interface IYieldbasisPool {

    function coins(
        uint256 i
    ) external view returns (address);
    function exchange(
        uint256 i,
        uint256 j,
        uint256 _dx,
        uint256 _min_dy,
        address _receiver
    ) external returns (uint256);

}