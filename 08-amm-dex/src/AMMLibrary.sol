// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AMMFactory} from "./AMMFactory.sol";
import {AMMPair} from "./AMMPair.sol";

/// @title AMMLibrary
/// @notice Pure pricing math for the constant-product AMM (Uniswap-V2-style): sorted token
///         lookup, optimal deposit quoting and in/out amount calculations with the 0.3% fee.
library AMMLibrary {
    error InsufficientAmount();
    error InsufficientLiquidity();

    /// @notice Returns tokens sorted by address — the canonical pair order.
    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    /// @notice Given some amount of an asset and pair reserves, returns the equivalent amount
    ///         of the other asset (spot price).
    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) internal pure returns (uint256 amountB) {
        if (amountA == 0) revert InsufficientAmount();
        if (reserveA == 0 || reserveB == 0) revert InsufficientLiquidity();
        amountB = amountA * reserveB / reserveA;
    }

    /// @notice Output amount for `amountIn` of `tokenIn`, given reserves. 0.3% fee included.
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert InsufficientAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    /// @notice Input amount needed to receive exactly `amountOut`. Rounds UP so the user
    ///         always sends at least enough.
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        internal
        pure
        returns (uint256 amountIn)
    {
        if (amountOut == 0) revert InsufficientAmount();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * 997;
        amountIn = numerator / denominator + 1;
    }

    /// @notice Output amounts for each hop of a swap path.
    function getAmountsOut(address factory, uint256 amountIn, address[] memory path)
        internal
        view
        returns (uint256[] memory amounts)
    {
        if (path.length < 2) revert InsufficientAmount();
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i = 0; i < path.length - 1; i++) {
            (uint256 reserveIn, uint256 reserveOut) = getReserves(factory, path[i], path[i + 1]);
            amounts[i + 1] = getAmountOut(amounts[i], reserveIn, reserveOut);
        }
    }

    /// @notice Input amounts for each hop to end with exactly `amountOut`.
    function getAmountsIn(address factory, uint256 amountOut, address[] memory path)
        internal
        view
        returns (uint256[] memory amounts)
    {
        if (path.length < 2) revert InsufficientAmount();
        amounts = new uint256[](path.length);
        amounts[amounts.length - 1] = amountOut;
        for (uint256 i = path.length - 1; i > 0; i--) {
            (uint256 reserveIn, uint256 reserveOut) = getReserves(factory, path[i - 1], path[i]);
            amounts[i - 1] = getAmountIn(amounts[i], reserveIn, reserveOut);
        }
    }

    /// @notice Fetches the pair's reserves, oriented to match (tokenA, tokenB) as given.
    function getReserves(address factory, address tokenA, address tokenB)
        internal
        view
        returns (uint256 reserveA, uint256 reserveB)
    {
        address pair = AMMFactory(factory).getPair(tokenA, tokenB);
        (uint112 r0, uint112 r1) = AMMPair(pair).getReserves();
        (reserveA, reserveB) = tokenA == AMMPair(pair).token0() ? (r0, r1) : (r1, r0);
    }

    /// @notice Returns the pair address for two tokens.
    function pairFor(address factory, address tokenA, address tokenB) internal view returns (address pair) {
        pair = AMMFactory(factory).getPair(tokenA, tokenB);
    }
}
