// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.24;

import {AprOracleBase} from "@periphery/AprOracle/AprOracleBase.sol";

import {ITroveManager} from "../interfaces/ITroveManager.sol";
import {IVaultAPROracle} from "../interfaces/IVaultAPROracle.sol";
import {IStrategyInterface as IStrategy} from "../interfaces/IStrategyInterface.sol";

contract StrategyAprOracle is AprOracleBase {

    // ===============================================================
    // Constants
    // ===============================================================

    /// @notice The WAD
    uint256 private constant WAD = 1e18;

    /// @notice The maximum basis points
    uint256 private constant MAX_BPS = 10_000;

    /// @notice The lender vault APR oracle contract
    IVaultAPROracle public constant VAULT_APR_ORACLE = IVaultAPROracle(0x1981AD9F44F2EA9aDd2dC4AD7D075c102C70aF92);

    // ===============================================================
    // Constructor
    // ===============================================================

    /// @param _governance Address of the Governance contract
    constructor(
        address _governance
    ) AprOracleBase("Liquity V2 Lender Borrower Strategy APR Oracle", _governance) {}

    // ===============================================================
    // View functions
    // ===============================================================

    /**
     * @notice Will return the expected Apr of a strategy post a debt change.
     * @dev _delta is a signed integer so that it can also represent a debt
     * decrease.
     *
     * This should return the annual expected return at the current timestamp
     * represented as 1e18.
     *
     *      ie. 10% == 1e17
     *
     * _delta will be == 0 to get the current apr.
     *
     * This will potentially be called during non-view functions so gas
     * efficiency should be taken into account.
     *
     * @param _strategy The token to get the apr for.
     * @param _delta The difference in debt.
     * @return . The expected apr for the strategy represented as 1e18.
     */
    function aprAfterDebtChange(address _strategy, int256 _delta) external view override returns (uint256) {
        IStrategy strategy_ = IStrategy(_strategy);
        uint256 _borrowApr =
            ITroveManager(strategy_.TROVE_MANAGER()).getLatestTroveData(strategy_.troveId()).annualInterestRate;
        uint256 _rewardApr = VAULT_APR_ORACLE.getStrategyApr(strategy_.STAKED_LENDER_VAULT(), _delta);
        if (_borrowApr >= _rewardApr) return 0;
        uint256 _targetLTV = (strategy_.getLiquidateCollateralFactor() * strategy_.targetLTVMultiplier()) / MAX_BPS;
        return (_rewardApr - _borrowApr) * _targetLTV / WAD;
    }

}
