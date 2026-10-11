// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {ShifaRegistry} from "./ShifaRegistry.sol";
import {ShifaConsent} from "./ShifaConsent.sol";
import {ShifaRecords} from "./ShifaRecords.sol";
import {ShifaPrescriptions} from "./ShifaPrescriptions.sol";
import {ShifaAppointments} from "./ShifaAppointments.sol";
import {ShifaInsurance} from "./ShifaInsurance.sol";
import {ShifaPayments} from "./ShifaPayments.sol";
import {ShifaEmergency} from "./ShifaEmergency.sol";
import {ShifaReputation} from "./ShifaReputation.sol";
import {ShifaTreasury} from "./ShifaTreasury.sol";

/// @title ShifaGovernor
/// @notice The platform's parliament. Voting power comes from provider
///         reputation, which is earned with completed, rated visits — patients
///         and clinics both hold a voice. Proposals touch fees, windows and
///         review rules, and they only run after a timelock.
contract ShifaGovernor is AccessControl {
    /// @notice The operator may propose urgent changes.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR");

    /// @notice One proposal.
    struct Proposal {
        address proposer;
        uint256 snapshotBlock;
        uint256 voteStart;
        uint256 voteEnd;
        uint256 executeAfter;
        uint256 forVotes;
        uint256 againstVotes;
        bool executed;
        bool canceled;
        address target;
        uint256 value;
        bytes calldataBytes;
        string description;
    }

    Proposal[] public proposals;

    mapping(uint256 proposalId => mapping(address voter => bool)) public hasVoted;

    /// @notice Quorum is a fixed reputation threshold voted on by governance.
    uint256 public quorumScore;
    uint256 public reviewPeriod;
    uint256 public votingPeriod;
    uint256 public timelock;

    ShifaRegistry public immutable registry;
    ShifaConsent public immutable consent;
    ShifaRecords public immutable records;
    ShifaPrescriptions public immutable prescriptions;
    ShifaAppointments public immutable appointments;
    ShifaInsurance public immutable insurance;
    ShifaPayments public immutable payments;
    ShifaEmergency public immutable emergency;
    ShifaReputation public immutable reputation;
    ShifaTreasury public immutable treasury;

    bool public paused;

    event ProposalCreated(uint256 indexed proposalId, address indexed proposer, string description);
    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalCanceled(uint256 indexed proposalId);
    event Paused(bool paused);

    error ZeroAddress();
    error InvalidTargets();
    error ProtocolPaused();
    error NotInVoting(uint256 proposalId);
    error AlreadyVoted(uint256 proposalId, address voter);
    error NotSucceeded(uint256 proposalId);
    error Timelocked(uint256 proposalId, uint256 executeAfter);
    error OnlyProposerOrOperator();
    error CallFailed();

    constructor(
        ShifaRegistry registry_,
        ShifaConsent consent_,
        ShifaRecords records_,
        ShifaPrescriptions prescriptions_,
        ShifaAppointments appointments_,
        ShifaInsurance insurance_,
        ShifaPayments payments_,
        ShifaEmergency emergency_,
        ShifaReputation reputation_,
        ShifaTreasury treasury_,
        uint256 quorumScore_
    ) {
        if (address(registry_) == address(0) || address(consent_) == address(0) || address(records_) == address(0) || address(prescriptions_) == address(0) || address(appointments_) == address(0) || address(insurance_) == address(0) || address(payments_) == address(0) || address(emergency_) == address(0) || address(reputation_) == address(0) || address(treasury_) == address(0)) {
            revert ZeroAddress();
        }
        registry = registry_;
        consent = consent_;
        records = records_;
        prescriptions = prescriptions_;
        appointments = appointments_;
        insurance = insurance_;
        payments = payments_;
        emergency = emergency_;
        reputation = reputation_;
        treasury = treasury_;
        quorumScore = quorumScore_;
        reviewPeriod = 2 days;
        votingPeriod = 5 days;
        timelock = 2 days;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    modifier whenNotPaused() {
        if (paused) revert ProtocolPaused();
        _;
    }

    /* ==================== PROPOSE ==================== */

    function propose(
        address target,
        uint256 value,
        bytes calldata calldataBytes,
        string calldata description
    ) external whenNotPaused returns (uint256 proposalId) {
        bool allowed =
            target == address(consent) ||
            target == address(records) ||
            target == address(prescriptions) ||
            target == address(appointments) ||
            target == address(insurance) ||
            target == address(payments) ||
            target == address(emergency) ||
            target == address(reputation) ||
            target == address(treasury) ||
            target == address(this);
        if (!allowed) revert InvalidTargets();

        proposalId = proposals.length;
        proposals.push();
        Proposal storage p = proposals[proposalId];
        p.proposer = msg.sender;
        p.snapshotBlock = block.number;
        p.voteStart = block.timestamp + reviewPeriod;
        p.voteEnd = p.voteStart + votingPeriod;
        p.executeAfter = p.voteEnd + timelock;
        p.target = target;
        p.value = value;
        p.calldataBytes = calldataBytes;
        p.description = description;
        emit ProposalCreated(proposalId, msg.sender, description);
    }

    /* ==================== VOTING ==================== */

    function vote(uint256 proposalId, bool support) external whenNotPaused {
        Proposal storage p = proposals[proposalId];
        if (block.timestamp < p.voteStart || block.timestamp > p.voteEnd) revert NotInVoting(proposalId);
        if (hasVoted[proposalId][msg.sender]) revert AlreadyVoted(proposalId, msg.sender);

        uint256 weight = reputation.getPastScore(msg.sender, p.snapshotBlock);
        if (weight == 0) revert NotInVoting(proposalId);

        hasVoted[proposalId][msg.sender] = true;
        if (support) p.forVotes += weight;
        else p.againstVotes += weight;
        emit VoteCast(proposalId, msg.sender, support, weight);
    }

    /* ==================== EXECUTION ==================== */

    function execute(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];
        if (block.timestamp < p.executeAfter) revert Timelocked(proposalId, p.executeAfter);
        if (state(proposalId) != 3) revert NotSucceeded(proposalId);
        p.executed = true;
        (bool ok, bytes memory returndata) = p.target.call{ value: p.value }(p.calldataBytes);
        if (!ok) {
            assembly {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }
        emit ProposalExecuted(proposalId);
    }

    function cancel(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];
        if (p.executed || p.canceled) revert NotSucceeded(proposalId);
        if (msg.sender != p.proposer && !hasRole(OPERATOR_ROLE, msg.sender)) revert OnlyProposerOrOperator();
        uint8 st = state(proposalId);
        if (st != 0 && st != 1 && st != 2) revert NotSucceeded(proposalId);
        p.canceled = true;
        emit ProposalCanceled(proposalId);
    }

    /// @dev 0 Review · 1 Voting · 2 Timelock · 3 Succeeded · 4 Executed · 5 Defeated · 6 Canceled
    function state(uint256 proposalId) public view returns (uint8) {
        Proposal storage p = proposals[proposalId];
        if (p.executed) return 4;
        if (p.canceled) return 6;
        if (block.timestamp < p.voteStart) return 0;
        if (block.timestamp <= p.voteEnd) return 1;
        if (p.forVotes < quorumScore || p.forVotes <= p.againstVotes) return 5;
        if (block.timestamp < p.executeAfter) return 2;
        return 3;
    }

    function quorum() public view returns (uint256) {
        return quorumScore;
    }

    /* ==================== PARAMETERS & GUARDIAN ==================== */

    function setQuorumScore(uint256 score) external onlySelf {
        quorumScore = score;
    }

    function setReviewPeriod(uint256 period) external onlySelf { reviewPeriod = period; }
    function setVotingPeriod(uint256 period) external onlySelf { votingPeriod = period; }
    function setTimelock(uint256 t) external onlySelf { timelock = t; }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        paused = true;
        emit Paused(true);
    }

    function unpause() external onlyRole(GUARDIAN_ROLE) {
        paused = false;
        emit Paused(false);
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlyProposerOrOperator();
        _;
    }
}
