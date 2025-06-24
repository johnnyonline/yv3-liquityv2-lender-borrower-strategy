// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

interface ISortedTroves {
    function findInsertPosition(uint256 _annualInterestRate, uint256 _prevId, uint256 _nextId)
        external
        view
        returns (uint256, uint256);
}
