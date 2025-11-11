// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {IStrategyInterface} from "../src/interfaces/IStrategyInterface.sol";
import {AggregatorInterface} from "../src/interfaces/AggregatorInterface.sol";

import "forge-std/Script.sol";

// ---- Usage ----
// forge script script/OpenTrove.s.sol:OpenTrove -g 200 --rpc-url $RPC_URL --broadcast

interface IWETH is IERC20 {
    function deposit() external payable;
}

contract OpenTrove is Script {

    uint256 private constant MAX_BPS = 10_000;
    uint256 private constant MIN_DEBT = 2_000 * 1e18;
    uint256 private constant ETH_GAS_COMPENSATION = 0.0375 ether;

    // Asym NG Deployer
    address private constant DEPLOYER = address(0x6969acca95B7fb9631a114085eEEBd161EC19f25);

    // WETH
    IWETH private constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    // tBTC LB Strategy
    IStrategyInterface private constant STRATEGY = IStrategyInterface(0x6dec370EfA894d48D8C55012B0Cd6f3C1C7C4616);

    function run() external {
        uint256 _privateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address _deployer = vm.addr(_privateKey);
        require(_deployer == DEPLOYER, "!deployer");

        IERC20 _asset = IERC20(STRATEGY.asset());

        AggregatorInterface _oracle = AggregatorInterface(STRATEGY.PRICE_FEED());
        (, int256 _price,,,) = _oracle.latestRoundData();

        uint256 _targetLTV = STRATEGY.getLiquidateCollateralFactor() * STRATEGY.targetLTVMultiplier() / MAX_BPS;
        uint256 _debtAmount = MIN_DEBT;
        uint256 _assetNeededInUSD = _debtAmount * 1e18 / _targetLTV;
        console2.log("Needed asset amount in USD: ", _assetNeededInUSD / 1e18);
        uint256 _assetNeeded = _assetNeededInUSD * 1e8 / uint256(_price);
        console2.log("Needed asset amount: ", _assetNeeded);

        // Make sure deployer has enough asset
        require(_asset.balanceOf(_deployer) >= _assetNeeded, "!asset balance");

        // Make sure deployer has enough ETH for gas compensation
        require(_deployer.balance >= ETH_GAS_COMPENSATION, "!eth balance");

        vm.startBroadcast(_privateKey);

        _asset.approve(address(STRATEGY), _assetNeeded);
        STRATEGY.deposit(_assetNeeded, _deployer);

        WETH.deposit{value: ETH_GAS_COMPENSATION}();
        WETH.approve(address(STRATEGY), ETH_GAS_COMPENSATION);

        // Find hints
        // (uint256 _upperHint, uint256 _lowerHint) = findHints();
        uint256 _upperHint = 0;
        uint256 _lowerHint = 0;

        // Open Trove
        STRATEGY.openTrove(_upperHint, _lowerHint);

        vm.stopBroadcast();

        // Sanity check
        require(STRATEGY.balanceOfLentAssets() >= 1999 * 1e18, "!lent assets");
        console2.log("Trove opened successfully with debt: ", STRATEGY.balanceOfLentAssets());
    }

}
