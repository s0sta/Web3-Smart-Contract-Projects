// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";

/// @title RahalaDisputes
/// @notice The arbitration desk: a 2-of-3 panel of arbiters reviews disputed
///         payments, files evidence hashes and issues binding awards that the
///         escrow enforces.
contract RahalaDisputes is AccessControl {
    /// @notice Arbiters vote on disputes.
    bytes32 public constant ARBITER_ROLE = keccak256("ARBITER");

    /// @notice One dispute.
    struct Dispute {
        uint256 paymentId; // the escrow payment under review
        address claimant;
        bytes32 evidenceHash;
        string summary;
        mapping(address arbiter => bool) voted;
        uint256 votesForRecipient;
        uint256 votesForSender;
        bool decided;
        bool toRecipient;
    }

    Dispute[] public disputes;

    uint256 public arbiterCount;

    event DisputeFiled(uint256 indexed disputeId, uint256 paymentId, address indexed claimant, bytes32 evidenceHash);
    event Voted(uint256 indexed disputeId, address indexed arbiter, bool toRecipient);
    event Awarded(uint256 indexed disputeId, bool toRecipient);

    error ZeroAddress();
    error UnknownDispute(uint256 disputeId);
    error AlreadyDecided(uint256 disputeId);
    error AlreadyVoted(uint256 disputeId, address arbiter);
    error NotArbiter();

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ARBITER_ROLE, msg.sender);
        arbiterCount = 3;
    }

    function setArbiterCount(uint256 n) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (n < 2 || n > 16) revert();
        arbiterCount = n;
    }

    function fileDispute(uint256 paymentId, bytes32 evidenceHash, string calldata summary) external returns (uint256 disputeId) {
        if (evidenceHash == bytes32(0)) revert ZeroAddress();
        disputeId = disputes.length;
        disputes.push();
        Dispute storage d = disputes[disputeId];
        d.paymentId = paymentId;
        d.claimant = msg.sender;
        d.evidenceHash = evidenceHash;
        d.summary = summary;
        emit DisputeFiled(disputeId, paymentId, msg.sender, evidenceHash);
    }

    /// @notice Arbiters vote on the award; 2 votes for the same side settle it.
    function vote(uint256 disputeId, bool toRecipient) external onlyRole(ARBITER_ROLE) {
        Dispute storage d = disputes[disputeId];
        if (d.claimant == address(0)) revert UnknownDispute(disputeId);
        if (d.decided) revert AlreadyDecided(disputeId);
        if (d.voted[msg.sender]) revert AlreadyVoted(disputeId, msg.sender);

        d.voted[msg.sender] = true;
        if (toRecipient) d.votesForRecipient += 1;
        else d.votesForSender += 1;
        emit Voted(disputeId, msg.sender, toRecipient);

        if (d.votesForRecipient >= 2 || d.votesForSender >= 2) {
            d.decided = true;
            d.toRecipient = d.votesForRecipient >= 2;
            emit Awarded(disputeId, d.toRecipient);
        }
    }
}
