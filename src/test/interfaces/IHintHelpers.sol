// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

interface IHintHelpers {
    function getApproxHint(uint256 _collIndex, uint256 _interestRate, uint256 _numTrials, uint256 _inputRandomSeed)
        external
        view
        returns (uint256 hintId, uint256 diff, uint256 latestRandomSeed);
}
