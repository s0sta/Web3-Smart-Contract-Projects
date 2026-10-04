// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {RahalaStable} from "./RahalaStable.sol";
import {RahalaCompliance} from "./RahalaCompliance.sol";
import {RahalaTreasury} from "./RahalaTreasury.sol";

/// @title RahalaEscrow
/// @notice The payment rail: a sender locks a payment into escrow for a
///         recipient; the payment releases instantly, after a timelock, or on
///         milestone approvals — and can be disputed to the arbitration desk.
contract RahalaEscrow is AccessControl {
    /// @notice The arbitration desk resolves disputed payments.
    bytes32 public constant DISPUTES_ROLE = keccak256("DISPUTES");

    /// @notice Release modes.
    enum Mode { Instant, Timelocked, Milestones }

    /// @notice One payment.
    struct Payment {
        address sender;
        address recipient;
        uint256 amount;
        uint256 milestones; // for Mode.Milestones: how many approvals unlock the payment
        uint256 approvals;
        uint64 releaseAfter; // for Mode.Timelocked
        bytes32 travelRuleMemo;
        uint64 recipientRegion;
        uint8 mode;
        bool claimed;
        bool refunded;
    }

    Payment[] public payments;

    uint256 public totalEscrowed;
    uint256 public totalReleased;
    uint256 public escrowFeeBps; // flat fee to the treasury on release

    RahalaStable public immutable settlement;
    RahalaCompliance public immutable compliance;
    RahalaTreasury public immutable treasury;

    event PaymentCreated(uint256 indexed paymentId, address indexed sender, address indexed recipient, uint256 amount, uint8 mode);
    event PaymentApproved(uint256 indexed paymentId, address indexed approver, uint256 approvals);
    event PaymentClaimed(uint256 indexed paymentId, uint256 amount);
    event PaymentRefunded(uint256 indexed paymentId, uint256 amount);
    event FeeSet(uint256 bps);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownPayment(uint256 paymentId);
    error NotSender(uint256 paymentId);
    error AlreadyClaimed(uint256 paymentId);
    error ReleaseLocked(uint256 paymentId, uint256 releaseAfter);
    error MilestonesPending(uint256 paymentId, uint256 approvals, uint256 needed);
    error TransferFailed();

    constructor(
        RahalaStable settlement_,
        RahalaCompliance compliance_,
        RahalaTreasury treasury_
    ) {
        if (address(settlement_) == address(0) || address(compliance_) == address(0) || address(treasury_) == address(0)) {
            revert ZeroAddress();
        }
        settlement = settlement_;
        compliance = compliance_;
        treasury = treasury_;
        escrowFeeBps = 25; // 0.25%
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(DISPUTES_ROLE, msg.sender);
    }

    /* ==================== CREATE ==================== */

    function createPayment(
        address recipient,
        uint256 amount,
        uint8 mode,
        uint256 milestones,
        uint64 releaseAfter,
        uint64 recipientRegion,
        bytes32 travelRuleMemo
    ) external returns (uint256 paymentId) {
        if (recipient == address(0) || amount == 0) revert ZeroAmount();
        if (mode == uint8(Mode.Milestones) && milestones == 0) revert ZeroAmount();
        if (mode == uint8(Mode.Timelocked) && releaseAfter <= block.timestamp) revert ReleaseLocked(0, releaseAfter);
        compliance.validateTransfer(msg.sender, recipient, recipientRegion, amount, travelRuleMemo);

        paymentId = payments.length;
        payments.push();
        Payment storage p = payments[paymentId];
        p.sender = msg.sender;
        p.recipient = recipient;
        p.amount = amount;
        p.milestones = milestones;
        p.releaseAfter = releaseAfter;
        p.travelRuleMemo = travelRuleMemo;
        p.recipientRegion = recipientRegion;
        p.mode = mode;

        totalEscrowed += amount;
        if (!settlement.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        emit PaymentCreated(paymentId, msg.sender, recipient, amount, mode);
    }

    /* ==================== RELEASE ==================== */

    /// @notice Anyone can approve a milestone payment (e.g. goods received).
    function approvePayment(uint256 paymentId) external {
        Payment storage p = payments[paymentId];
        if (p.sender == address(0)) revert UnknownPayment(paymentId);
        if (p.mode != uint8(Mode.Milestones)) revert MilestonesPending(paymentId, 0, 0);
        if (p.approvals >= p.milestones) revert AlreadyClaimed(paymentId);
        p.approvals += 1;
        emit PaymentApproved(paymentId, msg.sender, p.approvals);
        if (p.approvals >= p.milestones) {
            _release(paymentId);
        }
    }

    /// @notice The recipient claims the payment once its condition is met.
    function claim(uint256 paymentId) external {
        Payment storage p = payments[paymentId];
        if (p.sender == address(0)) revert UnknownPayment(paymentId);
        if (msg.sender != p.recipient) revert NotSender(paymentId);
        if (p.claimed || p.refunded) revert AlreadyClaimed(paymentId);
        if (p.mode == uint8(Mode.Timelocked) && block.timestamp < p.releaseAfter) {
            revert ReleaseLocked(paymentId, p.releaseAfter);
        }
        if (p.mode == uint8(Mode.Milestones) && p.approvals < p.milestones) {
            revert MilestonesPending(paymentId, p.approvals, p.milestones);
        }
        _release(paymentId);
    }

    function _release(uint256 paymentId) internal {
        Payment storage p = payments[paymentId];
        p.claimed = true;
        uint256 fee = (p.amount * escrowFeeBps) / 10_000;
        uint256 net = p.amount - fee;
        totalEscrowed -= p.amount;
        totalReleased += net;
        if (!settlement.transfer(p.recipient, net)) revert TransferFailed();
        if (fee > 0) {
            if (!settlement.approve(address(treasury), fee)) revert TransferFailed();
            treasury.receiveFees(fee);
        }
        emit PaymentClaimed(paymentId, net);
    }

    /* ==================== REFUND & DISPUTES ==================== */

    /// @notice The sender can refund while the payment is still locked.
    function refund(uint256 paymentId) external {
        Payment storage p = payments[paymentId];
        if (p.sender == address(0)) revert UnknownPayment(paymentId);
        if (msg.sender != p.sender) revert NotSender(paymentId);
        if (p.claimed || p.refunded) revert AlreadyClaimed(paymentId);
        if (p.mode == uint8(Mode.Timelocked) && block.timestamp >= p.releaseAfter) {
            revert ReleaseLocked(paymentId, p.releaseAfter);
        }
        p.refunded = true;
        totalEscrowed -= p.amount;
        if (!settlement.transfer(p.sender, p.amount)) revert TransferFailed();
        emit PaymentRefunded(paymentId, p.amount);
    }

    /// @notice The arbitration desk resolves a disputed payment.
    function resolveDispute(uint256 paymentId, bool toRecipient) external onlyRole(DISPUTES_ROLE) {
        Payment storage p = payments[paymentId];
        if (p.sender == address(0)) revert UnknownPayment(paymentId);
        if (p.claimed || p.refunded) revert AlreadyClaimed(paymentId);
        if (toRecipient) {
            _release(paymentId);
        } else {
            p.refunded = true;
            totalEscrowed -= p.amount;
            if (!settlement.transfer(p.sender, p.amount)) revert TransferFailed();
            emit PaymentRefunded(paymentId, p.amount);
        }
    }

    function setEscrowFee(uint256 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > 1000) revert ZeroAmount();
        escrowFeeBps = bps;
        emit FeeSet(bps);
    }
}
