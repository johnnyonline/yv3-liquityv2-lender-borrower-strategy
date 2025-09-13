// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {
    LiquityV2LBStrategy as Strategy,
    AggregatorInterface,
    IAddressesRegistry,
    IExchange,
    IStrategy
} from "./Strategy.sol";
import {IStrategyInterface} from "./interfaces/IStrategyInterface.sol";

contract StrategyFactory {

    event NewStrategy(address indexed strategy, address indexed asset);

    address public immutable emergencyAdmin;

    address public management;
    address public performanceFeeRecipient;
    address public keeper;

    /// @notice Track the deployments. asset => pool => strategy
    mapping(address => address) public deployments;

    constructor(address _management, address _performanceFeeRecipient, address _keeper, address _emergencyAdmin) {
        management = _management;
        performanceFeeRecipient = _performanceFeeRecipient;
        keeper = _keeper;
        emergencyAdmin = _emergencyAdmin;
    }

    /**
     * @notice Deploy a new Strategy.
     * @param _addressesRegistry The address registry of the Liquity collateral branch.
     * @param _priceFeed The price feed for the asset.
     * @param _exchange The exchange to use for swapping.
     * @return . The address of the new strategy.
     */
    function newStrategy(
        IAddressesRegistry _addressesRegistry,
        AggregatorInterface _priceFeed,
        IExchange _exchange,
        string calldata _name
    ) external virtual returns (address) {
        // tokenized strategies available setters.
        IStrategyInterface _newStrategy =
            IStrategyInterface(address(new Strategy(_addressesRegistry, _priceFeed, _exchange, _name)));

        _newStrategy.setPerformanceFeeRecipient(performanceFeeRecipient);

        _newStrategy.setKeeper(keeper);

        _newStrategy.setPendingManagement(management);

        _newStrategy.setEmergencyAdmin(emergencyAdmin);

        address _asset = _addressesRegistry.collToken();
        emit NewStrategy(address(_newStrategy), _asset);

        deployments[_asset] = address(_newStrategy);
        return address(_newStrategy);
    }

    function setAddresses(address _management, address _performanceFeeRecipient, address _keeper) external {
        require(msg.sender == management, "!management");
        management = _management;
        performanceFeeRecipient = _performanceFeeRecipient;
        keeper = _keeper;
    }

    function isDeployedStrategy(
        address _strategy
    ) external view returns (bool) {
        address _asset = IStrategyInterface(_strategy).asset();
        return deployments[_asset] == _strategy;
    }

}
