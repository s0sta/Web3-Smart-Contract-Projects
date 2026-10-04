// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";
import {AccessControl} from "./AccessControl.sol";

/// @title SilsilaTreasury
/// @notice The platform fee engine: collects payment and insurance fees behind
///         a reserve floor, pays approved service providers and drains on
///         guardian authority.
contract SilsilaTreasury is AccessControl {
    /// @notice The operator approves payees.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR");

    IERC20 public immutable paymentToken;

    uint256 public reserveBps;
    uint256 public totalFeesCollected;
    uint256 public totalPaidOut;

    mapping(address payee => bool) public approvedPayees;

    event FeesReceived(address indexed from, uint256 amount);
    event Paid(address indexed to, uint256 amount);
    event PayeeSet(address indexed payee, bool approved);
    event ReserveSet(uint256 bps);
    event Drained(address indexed to, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error ReserveBreach(uint256 available, uint256 needed);
    error TransferFailed();

    constructor(IERC20 paymentToken_, uint256 reserveBps_) {
        if (address(paymentToken_) == address(0)) revert ZeroAddress();
        paymentToken = paymentToken_;
        reserveBps = reserveBps_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    function receiveFees(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (!paymentToken.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        totalFeesCollected += amount;
        emit FeesReceived(msg.sender, amount);
    }

    function pay(address to, uint256 amount) external onlyRole(OPERATOR_ROLE) {
        if (to == address(0) || amount == 0) revert ZeroAmount();
        uint256 balance = paymentToken.balanceOf(address(this));
        uint256 required = (balance * reserveBps) / 10_000;
        if (balance - amount < required) revert ReserveBreach(balance - amount, required);
        totalPaidOut += amount;
        if (!paymentToken.transfer(to, amount)) revert TransferFailed();
        emit Paid(to, amount);
    }

    function setPayee(address payee, bool approved) external onlyRole(OPERATOR_ROLE) {
        if (payee == address(0)) revert ZeroAddress();
        approvedPayees[payee] = approved;
        emit PayeeSet(payee, approved);
    }

    function setReserveBps(uint256 bps) external onlyRole(OPERATOR_ROLE) {
        if (bps > 10_000) revert ZeroAmount();
        reserveBps = bps;
        emit ReserveSet(bps);
    }

    function drain(address to) external onlyRole(GUARDIAN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        uint256 balance = paymentToken.balanceOf(address(this));
        if (balance > 0) {
            if (!paymentToken.transfer(to, balance)) revert TransferFailed();
        }
        emit Drained(to, balance);
    }
}
