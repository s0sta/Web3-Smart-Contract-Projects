// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./IERC20.sol";
import {ERC20} from "./ERC20.sol";
import {IAMMCallee} from "./IAMMCallee.sol";

/// @title AMMPair
/// @notice A Uniswap-V2-style liquidity pool with the constant-product invariant x·y = k.
///         Holds two ERC-20s, mints LP tokens to liquidity providers, swaps with a 0.3% fee
///         that stays in the pool (accruing to LPs), and supports flash swaps.
/// @dev Architecture follows Uniswap V2 closely (balance-delta accounting, unlocked-flag
///      reentrancy lock, MINIMUM_LIQUIDITY). No oracle functionality in this version.
contract AMMPair is ERC20 {
    /// @notice Address of the factory that deployed this pair.
    address public immutable factory;

    /// @notice The two pooled tokens (sorted by address at initialization).
    address public token0;
    address public token1;

    uint112 private reserve0;
    uint112 private reserve1;

    /// @notice Liquidity forever locked at pool creation to protect the initial LP.
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    /// @dev V2-style reentrancy lock (1 = open, 0 = locked).
    uint256 private unlocked = 1;

    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    event Swap(address indexed sender, uint256 amount0Out, uint256 amount1Out, address indexed to);
    event Sync(uint112 reserve0, uint112 reserve1);

    error NotFactory();
    error AlreadyInitialized();
    error Locked();
    error InsufficientLiquidityMinted();
    error InsufficientLiquidityBurned();
    error InsufficientOutputAmount();
    error InsufficientLiquidity();
    error InsufficientInputAmount();
    error K();
    error Overflow();

    modifier lock() {
        if (unlocked == 0) revert Locked();
        unlocked = 0;
        _;
        unlocked = 1;
    }

    constructor() ERC20("AMM LP Token", "AMM-LP") {
        factory = msg.sender;
    }

    /// @notice Called once by the factory to set the pooled tokens (sorted order).
    function initialize(address token0_, address token1_) external {
        if (msg.sender != factory) revert NotFactory();
        if (token0 != address(0)) revert AlreadyInitialized();
        token0 = token0_;
        token1 = token1_;
    }

    function getReserves() public view returns (uint112 r0, uint112 r1) {
        r0 = reserve0;
        r1 = reserve1;
    }

    /* ==================== LIQUIDITY ==================== */

    /// @notice Mints LP tokens for `to` based on the tokens sent to the pair since the last
    ///         sync. Callers must transfer the underlying tokens BEFORE calling mint.
    function mint(address to) external lock returns (uint256 liquidity) {
        (uint112 r0, uint112 r1) = getReserves();
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - r0;
        uint256 amount1 = balance1 - r1;

        if (totalSupply == 0) {
            liquidity = sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mint(address(0), MINIMUM_LIQUIDITY); // permanently locked
        } else {
            liquidity = min(amount0 * totalSupply / r0, amount1 * totalSupply / r1);
        }
        if (liquidity == 0) revert InsufficientLiquidityMinted();
        _mint(to, liquidity);

        _update(balance0, balance1);
        emit Mint(msg.sender, amount0, amount1);
    }

    /// @notice Burns the LP tokens held by this contract and returns the proportional share of
    ///         both reserves (including accrued fees) to `to`. Callers must transfer their LP
    ///         tokens to the pair BEFORE calling burn.
    function burn(address to) external lock returns (uint256 amount0, uint256 amount1) {
        (uint112 r0, uint112 r1) = getReserves();
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        uint256 liquidity = balanceOf[address(this)];

        amount0 = liquidity * balance0 / totalSupply;
        amount1 = liquidity * balance1 / totalSupply;
        if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidityBurned();
        _burn(address(this), liquidity);
        IERC20(token0).transfer(to, amount0);
        IERC20(token1).transfer(to, amount1);

        balance0 = IERC20(token0).balanceOf(address(this));
        balance1 = IERC20(token1).balanceOf(address(this));
        _update(balance0, balance1);
        emit Burn(msg.sender, amount0, amount1, to);
    }

    /* ==================== SWAP ==================== */

    /// @notice Swaps tokens out. The caller must have already sent the input tokens (or, for
    ///         a flash swap, repay them during the `ammCall` callback if `data` is non-empty).
    ///         After the swap, the invariant must hold: (r0'·1000 − in0·3) · (r1'·1000 − in1·3)
    ///         ≥ r0·r1·1000² — i.e. the 0.3% fee stays in the pool.
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external lock {
        if (amount0Out == 0 && amount1Out == 0) revert InsufficientOutputAmount();
        (uint112 r0, uint112 r1) = getReserves();
        if (amount0Out >= r0 || amount1Out >= r1) revert InsufficientLiquidity();

        if (amount0Out > 0) IERC20(token0).transfer(to, amount0Out);
        if (amount1Out > 0) IERC20(token1).transfer(to, amount1Out);
        if (data.length > 0) IAMMCallee(to).ammCall(msg.sender, amount0Out, amount1Out, data);

        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        uint256 amount0In = balance0 > r0 - amount0Out ? balance0 - (r0 - amount0Out) : 0;
        uint256 amount1In = balance1 > r1 - amount1Out ? balance1 - (r1 - amount1Out) : 0;
        if (amount0In == 0 && amount1In == 0) revert InsufficientInputAmount();

        uint256 balance0Adjusted = balance0 * 1000 - amount0In * 3;
        uint256 balance1Adjusted = balance1 * 1000 - amount1In * 3;
        if (balance0Adjusted * balance1Adjusted < uint256(r0) * r1 * 1_000_000) revert K();

        _update(balance0, balance1);
        emit Swap(msg.sender, amount0Out, amount1Out, to);
    }

    /* ==================== MAINTENANCE ==================== */

    /// @notice Sends any excess token balances (above the recorded reserves) to `to`.
    function skim(address to) external lock {
        IERC20(token0).transfer(to, IERC20(token0).balanceOf(address(this)) - reserve0);
        IERC20(token1).transfer(to, IERC20(token1).balanceOf(address(this)) - reserve1);
    }

    /// @notice Re-syncs the recorded reserves with the current balances. Used after tokens
    ///         were sent directly to the pair (e.g. donations).
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)));
    }

    /* ==================== INTERNALS ==================== */

    function _update(uint256 balance0, uint256 balance1) private {
        if (balance0 > type(uint112).max || balance1 > type(uint112).max) revert Overflow();
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        emit Sync(uint112(balance0), uint112(balance1));
    }

    function min(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x < y ? x : y;
    }

    /// @dev Babylonian method (same algorithm as Uniswap V2's Math.sqrt).
    function sqrt(uint256 y) internal pure returns (uint256 z) {
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
}
