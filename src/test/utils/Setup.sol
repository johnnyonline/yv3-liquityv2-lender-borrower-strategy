// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/console2.sol";
import {Test} from "forge-std/Test.sol";

import {ETHToBOLDExchange as Exchange} from "../../periphery/Exchange.sol";
import {LiquityV2LBStrategy as Strategy, ERC20, AggregatorInterface, IAddressesRegistry, IExchange, IStrategy} from "../../Strategy.sol";
import {StrategyFactory} from "../../StrategyFactory.sol";
import {IStrategyInterface} from "../../interfaces/IStrategyInterface.sol";
import {IExchange} from "../../interfaces/IExchange.sol";
import {ITroveManager} from "../../interfaces/ITroveManager.sol";

import {ICollateralRegistry} from "../interfaces/ICollateralRegistry.sol";
import {ISortedTroves} from "../interfaces/ISortedTroves.sol";
import {IHintHelpers} from "../interfaces/IHintHelpers.sol";

// Inherit the events so they can be checked if desired.
import {IEvents} from "@tokenized-strategy/interfaces/IEvents.sol";

interface IFactory {

    function governance() external view returns (address);

    function set_protocol_fee_bps(
        uint16
    ) external;

    function set_protocol_fee_recipient(
        address
    ) external;

}

contract Setup is Test, IEvents {

    // Token addresses used in the tests.
    address public stybold = 0x23346B04a7f55b8760E5860AA5A77383D63491cD; // st-yBOLD
    IStrategyInterface public lenderVault = IStrategyInterface(stybold);

    // Liquity WETH
    address public collateralRegistry = 0xf949982B91C8c61e952B3bA942cbbfaef5386684;
    address public addressesRegistry = 0x20F7C9ad66983F6523a0881d0f82406541417526;
    address public borrowerOperations = 0x372ABD1810eAF23Cb9D941BbE7596DFb2c46BC65;
    address public troveManager = 0x7bcb64B2c9206a5B699eD43363f6F98D4776Cf5A;
    address public hintHelpers = 0xF0caE19C96E572234398d6665cC1147A16cBe657;
    address public sortedTroves = 0xA25269E41BD072513849F2E64Ad221e84f3063F4;
    uint256 public branchIndex = 0;
    uint256 public liquidateCollateralFactor = 909090909090909090;

    // Contract instances that we will use repeatedly.
    ERC20 public asset;
    IStrategyInterface public strategy;
    IExchange public exchange;

    StrategyFactory public strategyFactory;

    mapping(string => address) public tokenAddrs;

    // Addresses for different roles we will use repeatedly.
    address public strategist = address(69);
    address public user = address(10);
    address public keeper = address(4);
    address public management = address(1);
    address public performanceFeeRecipient = address(3);
    address public emergencyAdmin = address(5);

    // Address of the real deployed Factory
    address public factory;

    // Integer variables that will be used repeatedly.
    uint256 public decimals;
    uint256 public MAX_BPS = 10_000;

    // Fuzz from $0.01 of 1e6 stable coins up to 100 of a 1e18 coin
    uint256 public maxFuzzAmount = 100 * 1e18;
    uint256 public minFuzzAmount = 10_000;

    // Default profit max unlock time is set for 10 days
    uint256 public profitMaxUnlockTime = 10 days;

    // Constants from the Strategy
    uint256 public constant ETH_GAS_COMPENSATION = 0.0375 ether;
    uint256 public constant MIN_ANNUAL_INTEREST_RATE = 1e18 / 100 / 2; // 0.5%
    uint256 public constant MIN_DEBT = 2_000 * 1e18;

    function setUp() public virtual {
        uint256 _blockNumber = 22_763_240; // Caching for faster tests
        vm.selectFork(vm.createFork(vm.envString("ETH_RPC_URL"), _blockNumber));

        _setTokenAddrs();

        // Set asset
        asset = ERC20(tokenAddrs["WETH"]);

        // Set decimals
        decimals = asset.decimals();

        strategyFactory = new StrategyFactory(management, performanceFeeRecipient, keeper, emergencyAdmin);

        // Deploy strategy and set variables
        strategy = IStrategyInterface(setUpStrategy());

        factory = strategy.FACTORY();

        // label all the used addresses for traces
        vm.label(keeper, "keeper");
        vm.label(factory, "factory");
        vm.label(address(asset), "asset");
        vm.label(management, "management");
        vm.label(address(strategy), "strategy");
        vm.label(performanceFeeRecipient, "performanceFeeRecipient");
    }

    function setUpStrategy() public returns (address) {
        exchange = new Exchange();

        // we save the strategy as a IStrategyInterface to give it the needed interface
        IStrategyInterface _strategy = IStrategyInterface(
            address(
                strategyFactory.newStrategy(
                    IAddressesRegistry(addressesRegistry),
                    IStrategy(stybold),
                    AggregatorInterface(address(0)),
                    IExchange(address(exchange)),
                    "Tokenized Strategy"
                )
            )
        );

        vm.prank(management);
        _strategy.acceptManagement();

        return address(_strategy);
    }

    function depositIntoStrategy(IStrategyInterface _strategy, address _user, uint256 _amount) public {
        vm.prank(_user);
        asset.approve(address(_strategy), _amount);

        vm.prank(_user);
        _strategy.deposit(_amount, _user);
    }

    function mintAndDepositIntoStrategy(IStrategyInterface _strategy, address _user, uint256 _amount) public {
        airdrop(asset, _user, _amount);
        depositIntoStrategy(_strategy, _user, _amount);
    }

    // For checking the amounts in the strategy
    function checkStrategyTotals(IStrategyInterface _strategy, uint256 _totalAssets, uint256 _totalDebt, uint256 _totalIdle) public {
        uint256 _assets = _strategy.totalAssets();
        uint256 _balance = ERC20(_strategy.asset()).balanceOf(address(_strategy));
        uint256 _idle = _balance > _assets ? _assets : _balance;
        uint256 _debt = _assets - _idle;
        assertEq(_assets, _totalAssets, "!totalAssets");
        assertEq(_debt, _totalDebt, "!totalDebt");
        assertEq(_idle, _totalIdle, "!totalIdle");
        assertEq(_totalAssets, _totalDebt + _totalIdle, "!Added");
    }

    function airdrop(ERC20 _asset, address _to, uint256 _amount) public {
        uint256 balanceBefore = _asset.balanceOf(_to);
        deal(address(_asset), _to, balanceBefore + _amount);
    }

    function setFees(uint16 _protocolFee, uint16 _performanceFee) public {
        address gov = IFactory(factory).governance();

        // Need to make sure there is a protocol fee recipient to set the fee.
        vm.prank(gov);
        IFactory(factory).set_protocol_fee_recipient(gov);

        vm.prank(gov);
        IFactory(factory).set_protocol_fee_bps(_protocolFee);

        vm.prank(management);
        strategy.setPerformanceFee(_performanceFee);
    }

    function _setTokenAddrs() internal {
        tokenAddrs["WBTC"] = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
        tokenAddrs["YFI"] = 0x0bc529c00C6401aEF6D220BE8C6Ea1667F6Ad93e;
        tokenAddrs["WETH"] = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        tokenAddrs["LINK"] = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
        tokenAddrs["USDT"] = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
        tokenAddrs["DAI"] = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
        tokenAddrs["USDC"] = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    }

    function simulateEarningInterest() public {
        // Airdrop some profit to st-yBOLD
        airdrop(ERC20(lenderVault.asset()), address(lenderVault), 100_000 ether);

        // Report profit
        vm.prank(0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7); // SMS
        lenderVault.report();

        // Unlock profit
        skip(lenderVault.profitMaxUnlockTime());

        // Make sure oracles are updated
        updateOracles();
    }

    // ===============================================================
    // Liquity helpers
    // ===============================================================

    function strategistDepositAndOpenTrove(
        bool _strategistDeposit
    ) public returns (uint256 _initialStrategistDeposit) {
        // Amount strategist deposits after deployment to open a trove
        _initialStrategistDeposit = 2 ether;

        // Deposit into strategy
        if (_strategistDeposit) mintAndDepositIntoStrategy(strategy, strategist, _initialStrategistDeposit);

        // Approve gas compensation spending
        airdrop(ERC20(tokenAddrs["WETH"]), management, ETH_GAS_COMPENSATION);
        vm.prank(management);
        ERC20(tokenAddrs["WETH"]).approve(address(strategy), ETH_GAS_COMPENSATION);

        // Open Trove
        (uint256 _upperHint, uint256 _lowerHint) = findHints();
        vm.prank(management);
        strategy.openTrove(_upperHint, _lowerHint);

        return _initialStrategistDeposit;
    }

    function findHints() internal view returns (uint256 _upperHint, uint256 _lowerHint) {
        // Find approx hint (off-chain)
        (uint256 _approxHint,,) = IHintHelpers(hintHelpers).getApproxHint({
            _collIndex: branchIndex,
            _interestRate: MIN_ANNUAL_INTEREST_RATE,
            _numTrials: sqrt(100 * ITroveManager(troveManager).getTroveIdsCount()),
            _inputRandomSeed: block.timestamp
        });

        // Find concrete insert position (off-chain)
        (_upperHint, _lowerHint) = ISortedTroves(sortedTroves).findInsertPosition(MIN_ANNUAL_INTEREST_RATE, _approxHint, _approxHint);
    }

    function sqrt(
        uint256 y
    ) private pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function updateOracles() public {
        AggregatorInterface oracle = AggregatorInterface(strategy.PRICE_FEED());
        (uint80 roundId, int256 answer, uint256 startedAt,, uint80 answeredInRound) = oracle.latestRoundData();
        vm.mockCall(
            address(oracle),
            abi.encodeWithSelector(AggregatorInterface.latestRoundData.selector),
            abi.encode(roundId, answer, startedAt, block.timestamp, answeredInRound)
        );
    }

    function dropCollateralPrice() public {
        AggregatorInterface oracle = AggregatorInterface(strategy.PRICE_FEED());
        int256 answer = oracle.latestAnswer();
        int256 newAnswer = answer * 70 / 100; // 30% drop
        vm.mockCall(
            address(oracle),
            abi.encodeWithSelector(AggregatorInterface.latestAnswer.selector),
            abi.encode(newAnswer) // 30% drop
        );

        (uint80 roundId,, uint256 startedAt,, uint80 answeredInRound) = oracle.latestRoundData();
        vm.mockCall(
            address(oracle),
            abi.encodeWithSelector(AggregatorInterface.latestRoundData.selector),
            abi.encode(roundId, newAnswer, startedAt, block.timestamp, answeredInRound)
        );
    }

    function simulateCollateralRedemption(uint256 _amount, bool _zombie) internal {
        address _redeemer = address(420420);
        airdrop(ERC20(strategy.borrowToken()), _redeemer, _amount);
        vm.prank(_redeemer);
        ICollateralRegistry(collateralRegistry).redeemCollateral(
            _amount,
            0, // max iterations
            1_000_000_000_000_000_000 // max fee percentage
        );
        if (_zombie) {
            require(uint8(ITroveManager(troveManager).getTroveStatus(strategy.troveId())) == uint8(ITroveManager.Status.zombie), "Trove not zombie");
        } else {
            require(uint8(ITroveManager(troveManager).getTroveStatus(strategy.troveId())) == uint8(ITroveManager.Status.active), "Trove not active");
        }
    }

    function simulateLiquidation() internal {
        require(uint8(ITroveManager(troveManager).getTroveStatus(strategy.troveId())) == uint8(ITroveManager.Status.active), "Trove not active");
        dropCollateralPrice();
        uint256[] memory troveArray = new uint256[](1);
        troveArray[0] = strategy.troveId();
        ITroveManager(troveManager).batchLiquidateTroves(troveArray);
        require(
            uint8(ITroveManager(troveManager).getTroveStatus(strategy.troveId())) == uint8(ITroveManager.Status.closedByLiquidation),
            "Trove not liquidated"
        );
    }

}
