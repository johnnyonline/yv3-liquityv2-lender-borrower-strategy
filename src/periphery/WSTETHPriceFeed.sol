// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.24;

import {IWSTETH} from "../interfaces/IWSTETH.sol";
import {AggregatorInterface} from "../interfaces/AggregatorInterface.sol";

contract WSTETHPriceFeed {

    uint256 private constant WSTETH_DECIMALS = 18;
    uint256 private constant PRICE_FEED_DECIMALS = 8;
    uint256 private constant PRICE_FEEDS_DECIMALS_DIFFERENCE = 10;

    IWSTETH public constant WSTETH = IWSTETH(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
    AggregatorInterface public constant CL_STETH_USD_PRICE_FEED =
        AggregatorInterface(0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8);

    constructor() {
        require(WSTETH.decimals() == WSTETH_DECIMALS, "!WSTETH");
        require(CL_STETH_USD_PRICE_FEED.decimals() == PRICE_FEED_DECIMALS, "!CL_STETH_USD_PRICE_FEED");
    }

    function decimals() external pure returns (uint8) {
        return uint8(PRICE_FEED_DECIMALS);
    }

    function latestAnswer() external view returns (int256) {
        int256 _stEthPerWstEth = int256(WSTETH.stEthPerToken() / 10 ** PRICE_FEEDS_DECIMALS_DIFFERENCE); // scale to 8 decimals
        return CL_STETH_USD_PRICE_FEED.latestAnswer() * _stEthPerWstEth / int256(10 ** PRICE_FEED_DECIMALS);
    }

}
