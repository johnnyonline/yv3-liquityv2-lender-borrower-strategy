// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

library LenderOps {

    // ===============================================================
    // View functions
    // ===============================================================

    /// @notice Returns the maximum amount of borrowed token we can lend
    /// @param _vault The vault contract (i.e. sUSDaf)
    /// @return The maximum amount of borrowed token we can lend
    function maxDeposit(IERC4626 _vault) external view returns (uint256) {
        return _vault.maxDeposit(address(this));
    }

    /// @notice Returns the maximum amount of assets we can withdraw from the vault
    /// @param _vault The vault contract (i.e. sUSDaf)
    /// @return The maximum amount of borrowed token we can withdraw from the vault
    function maxWithdraw(IERC4626 _vault) external view returns (uint256) {
        return _vault.maxWithdraw(address(this));
    }

    /// @notice Returns the amount of borrow token we have lent
    /// @param _vault The vault contract (i.e. sUSDaf)
    /// @return The amount of borrow token we have lent
    function balanceOfAssets(IERC4626 _vault) external view returns (uint256) {
        return _vault.convertToAssets(_vault.balanceOf(address(this)));
    }

    // ===============================================================
    // Write functions
    // ===============================================================

    /// @notice Deposits borrowed tokens into the vault
    /// @param _vault The vault contract (i.e. sUSDaf)
    /// @param _amount The amount of tokens to deposit
    function lend(IERC4626 _vault, uint256 _amount) external {
        _vault.deposit(_amount, address(this));
    }

    /// @notice Withdraws tokens from the vault
    /// @param _vault The vault contract (i.e. sUSDaf)
    /// @param _amount The amount of tokens to withdraw
    function withdraw(IERC4626 _vault, uint256 _amount) external {
        if (_amount > 0) {
            // How much sUSDaf
            uint256 _shares = Math.min(_vault.previewWithdraw(_amount), _vault.balanceOf(address(this)));

            // Redeem sUSDaf to USDaf
            _vault.redeem(_shares, address(this), address(this));
        }
    }

}
