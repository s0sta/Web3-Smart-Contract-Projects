// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./IERC20.sol";
import {AMMPair} from "./AMMPair.sol";

/// @title AMMFactory
/// @notice Creates AMM pairs for any token combination, like Uniswap V2's factory.
///         The token pair (tokenA, tokenB) always maps to the same pool regardless of order.
contract AMMFactory {
    /// @notice pool lookup: getPair[tokenA][tokenB] → pool address (both orders indexed).
    mapping(address => mapping(address => address)) public getPair;

    /// @notice Every pool ever created.
    address[] public allPairs;

    event PairCreated(address indexed token0, address indexed token1, address pair, uint256 length);

    error IdenticalAddresses();
    error ZeroAddress();
    error PairExists();

    /// @notice Creates the pool for `tokenA`/`tokenB` if it does not exist yet.
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        if (tokenA == tokenB) revert IdenticalAddresses();
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (token0 == address(0)) revert ZeroAddress();
        if (getPair[token0][token1] != address(0)) revert PairExists();

        AMMPair p = new AMMPair();
        p.initialize(token0, token1);
        getPair[token0][token1] = address(p);
        getPair[token1][token0] = address(p);
        allPairs.push(address(p));
        emit PairCreated(token0, token1, address(p), allPairs.length);
        return address(p);
    }

    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }
}
