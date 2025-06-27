// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.23;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

library LenderOps {

    // ===============================================================
    // View functions
    // ===============================================================

    function maxDeposit(IERC4626 _staker, IERC4626 _vault) external view returns (uint256) {
        return Math.min(_vault.maxDeposit(address(this)), _vault.convertToAssets(_staker.maxDeposit(address(this))));
    }

    function maxWithdraw(IERC4626 _staker, IERC4626 _vault) external view returns (uint256) {
        return _vault.convertToAssets(_staker.convertToAssets(_staker.maxRedeem(address(this))));
    }

    function balanceOfAssets(IERC4626 _staker, IERC4626 _vault) external view returns (uint256) {
        return _vault.convertToAssets(_staker.convertToAssets(_staker.balanceOf(address(this))));
    }

    // ===============================================================
    // Write functions
    // ===============================================================

    function lend(IERC4626 _staker, IERC4626 _vault, uint256 _amount) external returns (uint256) {
        _staker.deposit(_vault.deposit(_amount, address(this)), address(this));
    }

    function withdraw(IERC4626 _staker, IERC4626 _vault, uint256 _amount) external returns (uint256) {
        if (_amount > 0) {
            uint256 _shares =
                Math.min(_vault.previewWithdraw(_amount), _staker.previewRedeem(_staker.balanceOf(address(this))));
            _shares = _staker.previewWithdraw(_shares);
            _shares = _staker.redeem(_shares, address(this), address(this));
            _vault.redeem(_shares, address(this), address(this));
        }
    }

}
