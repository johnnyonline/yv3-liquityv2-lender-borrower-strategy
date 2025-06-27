// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

library LenderOps {

    // ===============================================================
    // View functions
    // ===============================================================

    /// @notice Returns the maximum amount of borrowed token we can lend
    /// @param _staker The staker contract (i.e. st-yBOLD)
    /// @param _vault The vault contract (i.e. yBOLD)
    /// @return The maximum amount of borrowed token we can lend
    function maxDeposit(IERC4626 _staker, IERC4626 _vault) external view returns (uint256) {
        return Math.min(_vault.maxDeposit(address(this)), _vault.convertToAssets(_staker.maxDeposit(address(this))));
    }

    /// @notice Returns the maximum amount of assets we can withdraw from the staker vault
    /// @param _staker The staker contract (i.e. st-yBOLD)
    /// @param _vault The vault contract (i.e. yBOLD)
    /// @return The maximum amount of borrowed token we can withdraw from the staker vault
    function maxWithdraw(IERC4626 _staker, IERC4626 _vault) external view returns (uint256) {
        return _vault.convertToAssets(_staker.convertToAssets(_staker.maxRedeem(address(this))));
    }

    /// @notice Returns the amount of borrow token we have lent
    /// @param _staker The staker contract (i.e. st-yBOLD)
    /// @param _vault The vault contract (i.e. yBOLD)
    /// @return The amount of borrow token we have lent
    function balanceOfAssets(IERC4626 _staker, IERC4626 _vault) external view returns (uint256) {
        return _vault.convertToAssets(_staker.convertToAssets(_staker.balanceOf(address(this))));
    }

    // ===============================================================
    // Write functions
    // ===============================================================

    /// @notice Deposits borrowed tokens into the staker vault
    /// @param _staker The staker contract (i.e. st-yBOLD)
    /// @param _vault The vault contract (i.e. yBOLD)
    /// @param _amount The amount of tokens to deposit
    function lend(IERC4626 _staker, IERC4626 _vault, uint256 _amount) external {
        _staker.deposit(_vault.deposit(_amount, address(this)), address(this));
    }

    /// @notice Withdraws tokens from the staker vault
    /// @param _staker The staker contract (i.e. st-yBOLD)
    /// @param _vault The vault contract (i.e. yBOLD)
    /// @param _amount The amount of tokens to withdraw
    function withdraw(IERC4626 _staker, IERC4626 _vault, uint256 _amount) external {
        if (_amount > 0) {
            // How much yBOLD
            uint256 _shares =
                Math.min(_vault.previewWithdraw(_amount), _staker.previewRedeem(_staker.balanceOf(address(this))));

            // How much st-yBOLD
            _shares = _staker.previewWithdraw(_shares);

            // Redeem st-yBOLD to yBOLD
            _shares = _staker.redeem(_shares, address(this), address(this));

            // Redeem yBOLD to BOLD
            _vault.redeem(_shares, address(this), address(this));
        }
    }

}
