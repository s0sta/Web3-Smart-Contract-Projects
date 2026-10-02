// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./IERC20.sol";
import {AMMFactory} from "./AMMFactory.sol";
import {AMMPair} from "./AMMPair.sol";
import {AMMLibrary} from "./AMMLibrary.sol";

/// @title AMMRouter
/// @notice User-facing entry point (Uniswap-V2-style): add/remove liquidity and swap along
///         multi-hop token paths with slippage protection and deadlines.
contract AMMRouter {
    AMMFactory public immutable factory;

    error Expired(uint256 deadline);
    error InsufficientAAmount();
    error InsufficientBAmount();
    error PairMissing();
    error ExcessiveInputAmount();
    error InsufficientOutputAmount();

    modifier ensure(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired(deadline);
        _;
    }

    constructor(AMMFactory factory_) {
        factory = factory_;
    }

    /* ==================== LIQUIDITY ==================== */

    /// @notice Adds liquidity to a pool, creating it if it does not exist. Sends at most
    ///         `amountADesired`/`amountBDesired`, never below the minimums, to `to`.
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        address pair = AMMLibrary.pairFor(address(factory), tokenA, tokenB);
        if (pair == address(0)) pair = factory.createPair(tokenA, tokenB);

        IERC20(tokenA).transferFrom(msg.sender, pair, amountA);
        IERC20(tokenB).transferFrom(msg.sender, pair, amountB);
        liquidity = AMMPair(pair).mint(to);
    }

    /// @notice Burns LP tokens and returns both underlying tokens with slippage protection.
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256 amountA, uint256 amountB) {
        address pair = AMMLibrary.pairFor(address(factory), tokenA, tokenB);
        if (pair == address(0)) revert PairMissing();
        AMMPair(pair).transferFrom(msg.sender, pair, liquidity); // send LP to the pair
        (uint256 amount0, uint256 amount1) = AMMPair(pair).burn(to);
        // The pair reports amounts in its sorted token order — reorder to the caller's.
        (address token0,) = AMMLibrary.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        if (amountA < amountAMin) revert InsufficientAAmount();
        if (amountB < amountBMin) revert InsufficientBAmount();
    }

    /* ==================== SWAPS ==================== */

    /// @notice Swaps an exact input amount along `path`, guaranteeing at least `amountOutMin`.
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        amounts = AMMLibrary.getAmountsOut(address(factory), amountIn, path);
        if (amounts[amounts.length - 1] < amountOutMin) revert InsufficientOutputAmount();
        IERC20(path[0]).transferFrom(msg.sender, AMMLibrary.pairFor(address(factory), path[0], path[1]), amounts[0]);
        _swap(amounts, path, to);
    }

    /// @notice Swaps to receive exactly `amountOut`, refunding any excess input. Caller must
    ///         approve more than the quoted input (rounding safety).
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external ensure(deadline) returns (uint256[] memory amounts) {
        amounts = AMMLibrary.getAmountsIn(address(factory), amountOut, path);
        if (amounts[0] > amountInMax) revert ExcessiveInputAmount();
        IERC20(path[0]).transferFrom(msg.sender, AMMLibrary.pairFor(address(factory), path[0], path[1]), amounts[0]);
        _swap(amounts, path, to);
    }

    /* ==================== QUOTES ==================== */

    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB)
        external
        pure
        returns (uint256 amountB)
    {
        return AMMLibrary.quote(amountA, reserveA, reserveB);
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        external
        pure
        returns (uint256 amountOut)
    {
        return AMMLibrary.getAmountOut(amountIn, reserveIn, reserveOut);
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts)
    {
        return AMMLibrary.getAmountsOut(address(factory), amountIn, path);
    }

    /* ==================== INTERNALS ==================== */

    /// @dev Quotes the optimal amounts respecting desired/mins (Uniswap-V2 algorithm).
    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) internal view returns (uint256 amountA, uint256 amountB) {
        if (AMMLibrary.pairFor(address(factory), tokenA, tokenB) == address(0)) {
            return (amountADesired, amountBDesired);
        }
        (uint256 reserveA, uint256 reserveB) = AMMLibrary.getReserves(address(factory), tokenA, tokenB);
        if (reserveA == 0 && reserveB == 0) return (amountADesired, amountBDesired);

        uint256 amountBOptimal = AMMLibrary.quote(amountADesired, reserveA, reserveB);
        if (amountBOptimal <= amountBDesired) {
            if (amountBOptimal < amountBMin) revert InsufficientBAmount();
            return (amountADesired, amountBOptimal);
        }
        uint256 amountAOptimal = AMMLibrary.quote(amountBDesired, reserveB, reserveA);
        // amountAOptimal <= amountADesired always holds (quote is exact)
        if (amountAOptimal < amountAMin) revert InsufficientAAmount();
        return (amountAOptimal, amountBDesired);
    }

    /// @dev Executes each hop of a swap path, forwarding intermediate tokens to the next pair.
    function _swap(uint256[] memory amounts, address[] memory path, address to) internal {
        for (uint256 i = 0; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = AMMLibrary.sortTokens(input, output);
            uint256 amountOut = amounts[i + 1];
            (uint256 amount0Out, uint256 amount1Out) =
                input == token0 ? (uint256(0), amountOut) : (amountOut, uint256(0));
            address to_ = i < path.length - 2
                ? AMMLibrary.pairFor(address(factory), output, path[i + 2])
                : to;
            AMMPair(AMMLibrary.pairFor(address(factory), input, output)).swap(amount0Out, amount1Out, to_, "");
        }
    }
}
