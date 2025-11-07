// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.24;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IExchange} from "../interfaces/IExchange.sol";
import {IYieldbasisPool} from "../interfaces/IYieldbasisPool.sol";
import {ICurveStableSwapNG} from "../interfaces/ICurveStableSwapNG.sol";

contract tBTCToUSDafExchange is IExchange {

    using SafeERC20 for IERC20;
    using SafeERC20 for IERC4626;

    // ===============================================================
    // Constants
    // ===============================================================

    /// @notice Address of SMS on Mainnet
    address public constant SMS = 0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7;

    /// @notice scrvUSD/USDaf Curve Pool
    int128 private constant SCRVUSD_INDEX_SCRVUSD_USDAF_CURVE_POOL = 0;
    int128 private constant USDAF_INDEX_SCRVUSD_USDAF_CURVE_POOL = 1;
    ICurveStableSwapNG private constant SCRVUSD_USDAF_CURVE_POOL = ICurveStableSwapNG(0x3bE454C4391690ab4DDae3Fb987c8147b8Ecc08A);

    /// @notice crvUSD/tBTC Yieldbasis Pool
    uint256 private constant CRVUSD_INDEX_CRVUSD_TBTC_POOL = 0;
    uint256 private constant TBTC_INDEX_CRVUSD_TBTC_POOL = 1;
    IYieldbasisPool private constant CRVUSD_TBTC_YB_POOL = IYieldbasisPool(0xf1F435B05D255a5dBdE37333C0f61DA6F69c6127);

    /// @notice Token addresses
    IERC4626 private constant SCRVUSD = IERC4626(0x0655977FEb2f289A4aB78af67BAB0d17aAb84367);
    IERC20 private constant CRVUSD = IERC20(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);
    IERC20 private constant USDAF = IERC20(0x9Cf12ccd6020b6888e4D4C4e4c7AcA33c1eB91f8);
    IERC20 private constant TBTC = IERC20(0x18084fbA666a33d37592fA2633fD49a74DD93a88);

    // ===============================================================
    // Constructor
    // ===============================================================

    constructor() {
        SCRVUSD.forceApprove(address(SCRVUSD_USDAF_CURVE_POOL), type(uint256).max);
        USDAF.forceApprove(address(SCRVUSD_USDAF_CURVE_POOL), type(uint256).max);
        CRVUSD.forceApprove(address(CRVUSD_TBTC_YB_POOL), type(uint256).max);
        TBTC.forceApprove(address(CRVUSD_TBTC_YB_POOL), type(uint256).max);
        CRVUSD.forceApprove(address(SCRVUSD), type(uint256).max);
    }

    // ============================================================================================
    // View functions
    // ============================================================================================

    /// @notice Returns the address of the borrow token
    /// @return Address of the borrow token
    function BORROW() external pure override returns (address) {
        return address(USDAF);
    }

    /// @notice Returns the address of the collateral token
    /// @return Address of the collateral token
    function COLLATERAL() external pure override returns (address) {
        return address(TBTC);
    }

    // ============================================================================================
    // Mutative functions
    // ============================================================================================

    /// @notice Swaps between the borrow token and the collateral token
    /// @param _amount Amount of tokens to swap
    /// @param _minAmount Minimum amount of tokens to receive
    /// @param _fromBorrow If true, swap from borrow token to the collateral token, false otherwise
    /// @return Amount of tokens received
    function swap(uint256 _amount, uint256 _minAmount, bool _fromBorrow) external override returns (uint256) {
        return _fromBorrow ? _swapFrom(_amount, _minAmount) : _swapTo(_amount, _minAmount);
    }

    /// @notice Sweep tokens from the contract
    /// @dev This contract should never hold any tokens
    /// @param _token The token to sweep
    function sweep(
        IERC20 _token
    ) external {
        require(msg.sender == SMS, "!caller");
        uint256 _balance = _token.balanceOf(address(this));
        require(_balance > 0, "!balance");
        _token.safeTransfer(SMS, _balance);
    }

    // ============================================================================================
    // Internal functions
    // ============================================================================================

    /// @notice Swaps from the borrow token to the collateral token
    /// @param _amount Amount of borrow tokens to swap
    /// @param _minAmount Minimum amount of collateral tokens to receive
    /// @return Amount of collateral tokens received
    function _swapFrom(uint256 _amount, uint256 _minAmount) internal returns (uint256) {
        // Pull USDaf
        USDAF.safeTransferFrom(msg.sender, address(this), _amount);

        // USDAf --> scrvUSD
        uint256 _amountOut = SCRVUSD_USDAF_CURVE_POOL.exchange(
            USDAF_INDEX_SCRVUSD_USDAF_CURVE_POOL,
            SCRVUSD_INDEX_SCRVUSD_USDAF_CURVE_POOL,
            _amount,
            0, // minAmount
            address(this) // receiver
        );

        // scrvUSD --> crvUSD
        _amountOut = SCRVUSD.redeem(_amountOut, address(this), address(this));

        // crvUSD --> tBTC
        _amountOut = CRVUSD_TBTC_YB_POOL.exchange(
            CRVUSD_INDEX_CRVUSD_TBTC_POOL,
            TBTC_INDEX_CRVUSD_TBTC_POOL,
            _amountOut,
            0, // minAmount
            msg.sender // receiver
        );

        require(_amountOut >= _minAmount, "slippage rekt you");

        return _amountOut;
    }

    /// @notice Swaps from the collateral token to the borrow token
    /// @param _amount Amount of collateral tokens to swap
    /// @param _minAmount Minimum amount of borrow tokens to receive
    /// @return Amount of borrow tokens received
    function _swapTo(uint256 _amount, uint256 _minAmount) internal returns (uint256) {
        // Pull tBTC
        TBTC.safeTransferFrom(msg.sender, address(this), _amount);

        // tBTC --> crvUSD
        uint256 _amountOut = CRVUSD_TBTC_YB_POOL.exchange(
            TBTC_INDEX_CRVUSD_TBTC_POOL,
            CRVUSD_INDEX_CRVUSD_TBTC_POOL,
            _amount,
            0, // minAmount
            address(this) // receiver
        );

        // crvUSD --> scrvUSD
        _amountOut = SCRVUSD.deposit(_amountOut, address(this));

        // scrvUSD --> USDAf
        _amountOut = SCRVUSD_USDAF_CURVE_POOL.exchange(
            SCRVUSD_INDEX_SCRVUSD_USDAF_CURVE_POOL,
            USDAF_INDEX_SCRVUSD_USDAF_CURVE_POOL,
            _amountOut,
            0, // minAmount
            msg.sender // receiver
        );

        require(_amountOut >= _minAmount, "slippage rekt you");

        return _amountOut;
    }

}
