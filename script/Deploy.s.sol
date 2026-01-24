// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import "forge-std/Script.sol";

import {IStrategyInterface} from "../src/interfaces/IStrategyInterface.sol";
import {IVaultAPROracle} from "../src/interfaces/IVaultAPROracle.sol";
import {IExchange} from "../src/interfaces/IExchange.sol";

import {StrategyAprOracle} from "../src/periphery/StrategyAprOracle.sol";
import {RETHPriceFeed} from "../src/periphery/RETHPriceFeed.sol";
import {WSTETHPriceFeed} from "../src/periphery/WSTETHPriceFeed.sol";
import {WETHToBOLDExchange} from "../src/periphery/WETHToBOLDExchange.sol";
import {WSTETHToBOLDExchange} from "../src/periphery/WSTETHToBOLDExchange.sol";
import {RETHToBOLDExchange} from "../src/periphery/RETHToBOLDExchange.sol";

// import {LiquityV2LBStrategy as Strategy} from "../src/Strategy.sol";
import {
    LiquityV2LBStrategy as Strategy,
    AggregatorInterface,
    IAddressesRegistry
} from "../src/Strategy.sol";

// ---- Usage ----

// deploy:
// forge script script/Deploy.s.sol:Deploy --verify -g 250 --slow --etherscan-api-key $KEY --rpc-url $RPC_URL --broadcast

contract Deploy is Script {

    address public constant SMS = 0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7; // SMS mainnet
    address public constant ACCOUNTANT = 0x5A74Cb32D36f2f517DB6f7b0A0591e09b22cDE69; // SMS mainnet accountant
    address public constant DEPLOYER = 0x285E3b1E82f74A99D07D2aD25e159E75382bB43B; // johnnyonline.eth
    address public constant STRATEGY_APR_ORACLE = 0x8D26d5251cf5E228a4Aa7698C8C75879cEBec807;

    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public constant RETH = 0xae78736Cd615f374D3085123A210448E74Fc6393;
    address public constant LENDER_VAULT = 0x23346B04a7f55b8760E5860AA5A77383D63491cD; // ysyBOLD
    address public constant MANAGEMENT = 0x285E3b1E82f74A99D07D2aD25e159E75382bB43B; // johnnyonline.eth
    address public constant YHAAS = 0x604e586F17cE106B64185A7a0d2c1Da5bAce711E; // yHAAS
    address public constant PERFORMANCE_FEE_RECIPIENT = ACCOUNTANT;
    address public constant EMERGENCY_ADMIN = MANAGEMENT;

    IVaultAPROracle public constant APR_ORACLE = IVaultAPROracle(0x1981AD9F44F2EA9aDd2dC4AD7D075c102C70aF92);

    function run() public {
        uint256 _pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address _deployer = vm.addr(_pk);
        require(_deployer == DEPLOYER, "!deployer");

        address _asset = WETH;
        // address _asset = WSTETH;
        // address _asset = RETH;

        vm.startBroadcast(_pk);

        string memory _name;
        IExchange _exchange;
        AggregatorInterface _priceFeed;
        IAddressesRegistry _addressesRegistry;
        if (_asset == WETH) {
            _name = "Liquity WETH/BOLD Lender Borrower";
            _exchange = IExchange(address(new WETHToBOLDExchange()));
            _addressesRegistry = IAddressesRegistry(0x20F7C9ad66983F6523a0881d0f82406541417526); // WETH addresses registry
            // _priceFeed = no need
        } else if (_asset == WSTETH) {
            _name = "Liquity wstETH/BOLD Lender Borrower";
            _exchange = IExchange(address(new WSTETHToBOLDExchange()));
            _addressesRegistry = IAddressesRegistry(0x8d733F7ea7c23Cbea7C613B6eBd845d46d3aAc54); // wstETH addresses registry
            _priceFeed = AggregatorInterface(address(new WSTETHPriceFeed()));
        } else if (_asset == RETH) {
            _name = "Liquity rETH/BOLD Lender Borrower";
            _exchange = IExchange(address(new RETHToBOLDExchange()));
            _addressesRegistry = IAddressesRegistry(0x6106046F031a22713697e04C08B330dDaf3e8789); // rETH addresses registry
            _priceFeed = AggregatorInterface(address(new RETHPriceFeed()));
        }

        // deploy strategy
        // address _oracle = address(new StrategyAprOracle());
        IStrategyInterface _newStrategy = IStrategyInterface(address(new Strategy(_addressesRegistry, _priceFeed, _exchange, _name)));

        // init
        _newStrategy.setPerformanceFeeRecipient(PERFORMANCE_FEE_RECIPIENT);
        // _newStrategy.setKeeper(YHAAS);
        _newStrategy.setPendingManagement(SMS);
        _newStrategy.setEmergencyAdmin(SMS);

        // set APR oracle
        APR_ORACLE.setOracle(address(_newStrategy), STRATEGY_APR_ORACLE);

        vm.stopBroadcast();

        console2.log("Exchange address: %s", address(_exchange));
        // console2.log("Oracle address: %s", address(_oracle));
        console2.log("Strategy address: %s", address(_newStrategy));
    }

}

// APR ORACLE: 0x8D26d5251cf5E228a4Aa7698C8C75879cEBec807
// RETH: 0x2fFff76ee152164f4dEfc95fB0cf88528251aB9E
// WSTETH: 0x2637F30242BB8EEd4E8C261Aa5B6EBf0E9b970ef
// WETH: 0x654973123cD5c7e3f47feE7E94a85B55E919f912