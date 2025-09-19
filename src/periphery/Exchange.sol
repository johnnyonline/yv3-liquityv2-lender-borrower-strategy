// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.24;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IExchange} from "../interfaces/IExchange.sol";
import {ICurveTricrypto} from "../interfaces/ICurveTricrypto.sol";
import {ICurveStableSwapNG} from "../interfaces/ICurveStableSwapNG.sol";

contract ETHToBOLDExchange is IExchange {

    using SafeERC20 for IERC20;

    // ===============================================================
    // Constants
    // ===============================================================

    /// @notice Address of SMS on Mainnet
    address public constant SMS = 0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7;

    /// @notice BOLD/USDC Curve Pool
    int128 private constant BOLD_INDEX_BOLD_USDC_CURVE_POOL = 0;
    int128 private constant USDC_INDEX_BOLD_USDC_CURVE_POOL = 1;
    ICurveStableSwapNG private constant BOLD_USDC_CURVE_POOL =
        ICurveStableSwapNG(0xEFc6516323FbD28e80B85A497B65A86243a54B3E);

    /// @notice WETH/USDC Curve Pool
    uint256 private constant USDC_INDEX_USDC_WETH_POOL = 0;
    uint256 private constant WETH_INDEX_USDC_WETH_POOL = 2;
    ICurveTricrypto private constant TRICRYPTO = ICurveTricrypto(0x7F86Bf177Dd4F3494b841a37e810A34dD56c829B);

    /// @notice Token addresses
    IERC20 private constant BOLD = IERC20(0x6440f144b7e50D6a8439336510312d2F54beB01D);
    IERC20 private constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 private constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    // ===============================================================
    // Constructor
    // ===============================================================

    constructor() {
        BOLD.forceApprove(address(BOLD_USDC_CURVE_POOL), type(uint256).max);
        USDC.forceApprove(address(BOLD_USDC_CURVE_POOL), type(uint256).max);
        USDC.forceApprove(address(TRICRYPTO), type(uint256).max);
        WETH.forceApprove(address(TRICRYPTO), type(uint256).max);
    }

    // ============================================================================================
    // View functions
    // ============================================================================================

    /// @notice Returns the address of the borrow token
    /// @return Address of the borrow token
    function BORROW() external pure override returns (address) {
        return address(BOLD);
    }

    /// @notice Returns the address of the collateral token
    /// @return Address of the collateral token
    function COLLATERAL() external pure override returns (address) {
        return address(WETH);
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
        // Pull BOLD
        BOLD.safeTransferFrom(msg.sender, address(this), _amount);

        // BOLD --> USDC
        uint256 _amountOut = BOLD_USDC_CURVE_POOL.exchange(
            BOLD_INDEX_BOLD_USDC_CURVE_POOL,
            USDC_INDEX_BOLD_USDC_CURVE_POOL,
            _amount,
            0, // minAmount
            address(this) // receiver
        );

        // USDC --> ETH
        _amountOut = TRICRYPTO.exchange(
            USDC_INDEX_USDC_WETH_POOL,
            WETH_INDEX_USDC_WETH_POOL,
            _amountOut,
            0, // minAmount
            false, // use_eth
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
        // Pull WETH
        WETH.safeTransferFrom(msg.sender, address(this), _amount);

        // WETH --> USDC
        uint256 _amountOut = TRICRYPTO.exchange(
            WETH_INDEX_USDC_WETH_POOL,
            USDC_INDEX_USDC_WETH_POOL,
            _amount,
            0, // minAmount
            false, // use_eth
            address(this) // receiver
        );

        // USDC --> BOLD
        _amountOut = BOLD_USDC_CURVE_POOL.exchange(
            USDC_INDEX_BOLD_USDC_CURVE_POOL,
            BOLD_INDEX_BOLD_USDC_CURVE_POOL,
            _amountOut,
            0, // minAmount
            msg.sender // receiver
        );

        require(_amountOut >= _minAmount, "slippage rekt you");

        return _amountOut;
    }

}
