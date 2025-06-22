// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {AggregatorInterface} from "./AggregatorInterface.sol";

interface IPriceFeed {

    struct Oracle {
        AggregatorInterface aggregator;
        uint256 stalenessThreshold;
        uint8 decimals;
    }

    function ethUsdOracle() external view returns (Oracle memory);

}
