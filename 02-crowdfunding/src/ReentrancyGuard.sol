// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title ReentrancyGuard
/// @notice From-scratch reentrancy protection: any function marked `nonReentrant` cannot be
///         re-entered while an earlier call is still executing.
/// @dev Uses a simple 1/2 state flag. Same idea as OpenZeppelin's ReentrancyGuard but
///      implemented by hand — see README for production guidance.
abstract contract ReentrancyGuard {
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;

    uint256 private _status = NOT_ENTERED;

    /// @notice Thrown when a protected function is called again before the first call finishes.
    error Reentrancy();

    modifier nonReentrant() {
        if (_status == ENTERED) revert Reentrancy();
        _status = ENTERED;
        _;
        _status = NOT_ENTERED;
    }
}
