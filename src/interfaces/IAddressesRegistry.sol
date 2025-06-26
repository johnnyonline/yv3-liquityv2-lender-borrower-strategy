// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {IPriceFeed} from "./IPriceFeed.sol";
import {ICollSurplusPool} from "./ICollSurplusPool.sol";
import {IBorrowerOperations} from "./IBorrowerOperations.sol";
import {ITroveManager} from "./ITroveManager.sol";

interface IAddressesRegistry {

    function collToken() external view returns (address);
    function boldToken() external view returns (address);
    function priceFeed() external view returns (IPriceFeed);
    function collSurplusPool() external view returns (ICollSurplusPool);
    function borrowerOperations() external view returns (IBorrowerOperations);
    function troveManager() external view returns (ITroveManager);

}
