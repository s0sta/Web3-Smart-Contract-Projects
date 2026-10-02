// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Receiver callback for flash-swaps: called when a swap is made with non-empty data.
interface IAMMCallee {
    function ammCall(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external;
}
