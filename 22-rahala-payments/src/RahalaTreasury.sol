// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {RahalaStable} from "./RahalaStable.sol";

/// @title RahalaTreasury
/// @notice The network's fee engine: collects escrow, FX and factoring fees
///         behind a reserve floor, pays approved vendors and drains on guardian
///         authority.
contract RahalaTreasury is AccessControl {
    /// @notice The operator approves vendors.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR");

    RahalaStable public immutable settlement;

    uint256 public reserveBps;
    uint256 public totalFeesCollected;
    uint256 public totalPaidOut;

    mapping(address vendor => bool) public approvedVendors;

    event FeesReceived(address indexed from, uint256 amount);
    event VendorPaid(address indexed to, uint256 amount);
    event VendorSet(address indexed vendor, bool approved);
    event ReserveSet(uint256 bps);
    event Drained(address indexed to, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error ReserveBreach(uint256 available, uint256 needed);
    error TransferFailed();

    constructor(RahalaStable settlement_, uint256 reserveBps_) {
        if (address(settlement_) == address(0)) revert ZeroAddress();
        settlement = settlement_;
        reserveBps = reserveBps_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    function receiveFees(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (!settlement.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        totalFeesCollected += amount;
        emit FeesReceived(msg.sender, amount);
    }

    function payVendor(address to, uint256 amount) external onlyRole(OPERATOR_ROLE) {
        if (to == address(0) || amount == 0) revert ZeroAmount();
        uint256 balance = settlement.balanceOf(address(this));
        uint256 required = (balance * reserveBps) / 10_000;
        if (balance - amount < required) revert ReserveBreach(balance - amount, required);
        totalPaidOut += amount;
        if (!settlement.transfer(to, amount)) revert TransferFailed();
        emit VendorPaid(to, amount);
    }

    function setVendor(address vendor, bool approved) external onlyRole(OPERATOR_ROLE) {
        if (vendor == address(0)) revert ZeroAddress();
        approvedVendors[vendor] = approved;
        emit VendorSet(vendor, approved);
    }

    function setReserveBps(uint256 bps) external onlyRole(OPERATOR_ROLE) {
        if (bps > 10_000) revert ZeroAmount();
        reserveBps = bps;
        emit ReserveSet(bps);
    }

    function drain(address to) external onlyRole(GUARDIAN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        uint256 balance = settlement.balanceOf(address(this));
        if (balance > 0) {
            if (!settlement.transfer(to, balance)) revert TransferFailed();
        }
        emit Drained(to, balance);
    }
}
