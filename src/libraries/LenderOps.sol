// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

library LenderOps {

    // ===============================================================
    // Constants
    // ===============================================================

    /// @notice The lender vault contract
    IERC4626 public constant LENDER_VAULT = IERC4626(0x9F4330700a36B29952869fac9b33f45EEdd8A3d8); // yBOLD

    /// @notice The staked lender vault contract
    IERC4626 public constant STAKED_LENDER_VAULT = IERC4626(0x23346B04a7f55b8760E5860AA5A77383D63491cD); // ysyBOLD

    // ===============================================================
    // View functions
    // ===============================================================

    /// @notice Returns the maximum amount of borrowed token we can lend
    /// @return The maximum amount of borrowed token we can lend
    function maxDeposit() external view returns (uint256) {
        return Math.min(
            LENDER_VAULT.maxDeposit(address(this)),
            LENDER_VAULT.convertToAssets(STAKED_LENDER_VAULT.maxDeposit(address(this)))
        );
    }

    /// @notice Returns the maximum amount of assets we can withdraw from the staker vault
    /// @return The maximum amount of borrowed token we can withdraw from the staker vault
    function maxWithdraw() external view returns (uint256) {
        return
            LENDER_VAULT.convertToAssets(
                STAKED_LENDER_VAULT.convertToAssets(STAKED_LENDER_VAULT.maxRedeem(address(this)))
            );
    }

    /// @notice Returns the amount of borrow token we have lent
    /// @return The amount of borrow token we have lent
    function balanceOfAssets() external view returns (uint256) {
        return
            LENDER_VAULT.convertToAssets(
                STAKED_LENDER_VAULT.convertToAssets(STAKED_LENDER_VAULT.balanceOf(address(this)))
            );
    }

    // ===============================================================
    // Write functions
    // ===============================================================

    /// @notice Deposits borrowed tokens into the staker vault
    /// @param _amount The amount of tokens to deposit
    function lend(
        uint256 _amount
    ) external {
        STAKED_LENDER_VAULT.deposit(LENDER_VAULT.deposit(_amount, address(this)), address(this));
    }

    /// @notice Withdraws tokens from the staker vault
    /// @param _amount The amount of tokens to withdraw
    function withdraw(
        uint256 _amount
    ) external {
        if (_amount > 0) {
            // How much yBOLD
            uint256 _shares = Math.min(
                LENDER_VAULT.previewWithdraw(_amount),
                STAKED_LENDER_VAULT.previewRedeem(STAKED_LENDER_VAULT.balanceOf(address(this)))
            );

            // How much ysyBOLD
            _shares = STAKED_LENDER_VAULT.previewWithdraw(_shares);

            // Redeem ysyBOLD to yBOLD
            _shares = STAKED_LENDER_VAULT.redeem(_shares, address(this), address(this));

            // Redeem yBOLD to BOLD
            LENDER_VAULT.redeem(_shares, address(this), address(this));
        }
    }

}
