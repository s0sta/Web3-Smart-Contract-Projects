// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Ownable
/// @notice Minimal single-owner access control with a two-step transfer.
/// @dev Implemented from scratch. The two-step transfer exists so ownership can never be
///      accidentally handed to an address nobody controls (e.g. a typo) — the new owner
///      must call `acceptOwnership` to prove they can sign from that address.
abstract contract Ownable {
    /// @notice The current owner — the only address that can call privileged functions.
    address public owner;

    /// @notice The address nominated to become the next owner (step 1 of a transfer).
    address public pendingOwner;

    /// @notice Emitted when a new owner is nominated. They must call `acceptOwnership`.
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);

    /// @notice Emitted when ownership actually changes hands.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @notice Thrown when a caller other than the owner invokes an `onlyOwner` function.
    error NotOwner(address caller);

    /// @notice Thrown when `acceptOwnership` is called by anyone but the pending owner.
    error NotPendingOwner(address caller);

    /// @notice Thrown when an operation involves the zero address.
    error ZeroAddress();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        _;
    }

    /// @param initialOwner The address that will own the contract from deployment.
    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
        owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    /// @notice Nominates `newOwner` as the pending owner. Ownership only changes after
    ///         `newOwner` calls `acceptOwnership`.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Called by the pending owner to complete a two-step ownership transfer.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner(msg.sender);
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    /// @notice Permanently renounces ownership, leaving privileged functions unreachable.
    /// @dev Irreversible — use only when ownership is genuinely no longer needed.
    function renounceOwnership() external onlyOwner {
        emit OwnershipTransferred(owner, address(0));
        owner = address(0);
        pendingOwner = address(0);
    }
}
