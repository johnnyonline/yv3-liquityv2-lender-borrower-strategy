// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.24;

import {AggregatorInterface} from "../interfaces/AggregatorInterface.sol";

contract RETHPriceFeed {

    uint256 private constant RETH_ETH_PRICE_FEED_DECIMALS = 18;
    uint256 private constant PRICE_FEED_DECIMALS = 8;
    uint256 private constant PRICE_FEEDS_DECIMALS_DIFFERENCE = 10;

    AggregatorInterface public constant CL_RETH_ETH_PRICE_FEED =
        AggregatorInterface(0x536218f9E9Eb48863970252233c8F271f554C2d0);
    AggregatorInterface public constant CL_ETH_USD_PRICE_FEED =
        AggregatorInterface(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);

    constructor() {
        require(CL_RETH_ETH_PRICE_FEED.decimals() == RETH_ETH_PRICE_FEED_DECIMALS, "!CL_RETH_ETH_PRICE_FEED");
        require(CL_ETH_USD_PRICE_FEED.decimals() == PRICE_FEED_DECIMALS, "!CL_ETH_USD_PRICE_FEED");
    }

    function decimals() external pure returns (uint8) {
        return uint8(PRICE_FEED_DECIMALS);
    }

    function latestAnswer() external view returns (int256) {
        int256 _rethEthScaledPrice =
            CL_RETH_ETH_PRICE_FEED.latestAnswer() / int256(10 ** PRICE_FEEDS_DECIMALS_DIFFERENCE); // scale to 8 decimals
        return CL_ETH_USD_PRICE_FEED.latestAnswer() * _rethEthScaledPrice / int256(10 ** PRICE_FEED_DECIMALS);
    }

}
