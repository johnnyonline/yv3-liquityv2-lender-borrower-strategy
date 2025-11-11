// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.24;

import {IStrategyInterface} from "../src/interfaces/IStrategyInterface.sol";

import {tBTCToUSDafExchange as Exchange} from "../src/periphery/Exchange.sol";
import {StrategyAprOracle} from "../src/periphery/StrategyAprOracle.sol";
import {
    LiquityV2LBStrategy as Strategy,
    AggregatorInterface,
    IAddressesRegistry,
    IExchange
} from "../src/Strategy.sol";

import "forge-std/Script.sol";

// ---- Usage ----
// forge script script/Deploy.s.sol:Deploy -g 200 --verify --etherscan-api-key $KEY --rpc-url $RPC_URL --broadcast

interface IAPROracle {
    function setOracle(address _strategy, address _oracle) external;
}

contract Deploy is Script {

    // Asym NG Deployer
    address private constant DEPLOYER = address(0x6969acca95B7fb9631a114085eEEBd161EC19f25);

    // USDaf's tBTC Addresses Registry
    IAddressesRegistry private constant ADDRESSES_REGISTRY = IAddressesRegistry(0xbd9f75471990041A3e7C22872c814A273485E999);

    // Strategy APR Oracle
    IAPROracle private constant APR_ORACLE = IAPROracle(0x1981AD9F44F2EA9aDd2dC4AD7D075c102C70aF92);

    function run() external {
        uint256 _privateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address _deployer = vm.addr(_privateKey);
        require(_deployer == DEPLOYER, "!deployer");

        vm.startBroadcast(_privateKey);

        IExchange _exchange = IExchange(address(new Exchange()));
        StrategyAprOracle _aprOracle = new StrategyAprOracle(DEPLOYER);

        Strategy _strategy = new Strategy(ADDRESSES_REGISTRY, AggregatorInterface(address(0)), _exchange, "Asymmetry tBTC LB Strategy");
        _strategy.setAllowed(DEPLOYER, true);

        IStrategyInterface _strategyInterface = IStrategyInterface(address(_strategy));
        _strategyInterface.setPerformanceFee(0);
        _strategyInterface.setPerformanceFeeRecipient(DEPLOYER);
        _strategyInterface.setKeeper(DEPLOYER);
        _strategyInterface.setEmergencyAdmin(DEPLOYER);
        // _strategyInterface.setPendingManagement(management);

        APR_ORACLE.setOracle(address(0x6dec370EfA894d48D8C55012B0Cd6f3C1C7C4616), address(_aprOracle));

        vm.stopBroadcast();

        console.log("Deployed Strategy at:", address(_strategy));
        console.log("Deployed Exchange at:", address(_exchange));
        console.log("Deployed Strategy APR Oracle at:", address(_aprOracle));
    }

}
