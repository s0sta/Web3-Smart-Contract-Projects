// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GovToken} from "./GovToken.sol";

/// @title Governor
/// @notice A DAO governor written from scratch: token holders propose and vote on arbitrary
///         on-chain actions, which execute automatically when they pass. Voting power is
///         snapshotted at proposal creation, so buying votes after the fact is impossible.
contract Governor {
    /// @notice Lifecycle of a proposal.
    enum ProposalState {
        Active,
        Succeeded,
        Defeated,
        Executed,
        Canceled
    }

    /// @notice One proposal: an arbitrary sequence of calls plus its voting record.
    struct Proposal {
        address proposer;
        uint256 snapshotBlock; // voting power is measured at this block
        uint256 deadline; // voting closes at this timestamp
        uint256 forVotes;
        uint256 againstVotes;
        bool executed;
        bool canceled;
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
        string description;
    }

    /// @notice The governance token.
    GovToken public immutable token;

    /// @notice How long voting stays open after a proposal is created.
    uint256 public votingPeriod;

    /// @notice Minimum past-votes required to create a proposal.
    uint256 public proposalThreshold;

    /// @notice Quorum as basis points of the total supply at the snapshot block.
    uint256 public quorumBps;

    Proposal[] public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    event ProposalCreated(uint256 indexed proposalId, address indexed proposer, uint256 deadline);
    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalCanceled(uint256 indexed proposalId);

    error BelowProposalThreshold(uint256 votes, uint256 threshold);
    error EmptyProposal();
    error LengthMismatch();
    error ZeroTarget();
    error AlreadyVoted(uint256 proposalId, address voter);
    error VotingEnded(uint256 proposalId);
    error NotProposer();
    error VotingActive();
    error ProposalNotSucceeded(uint256 proposalId);
    error ExecutionFailed(uint256 callIndex);

    /// @param token_ The governance token (fixed supply, snapshot-capable).
    /// @param votingPeriod_ Seconds proposals stay open.
    /// @param proposalThreshold_ Past-votes required to propose.
    /// @param quorumBps_ Quorum as basis points of snapshot total supply (400 = 4%).
    constructor(GovToken token_, uint256 votingPeriod_, uint256 proposalThreshold_, uint256 quorumBps_) {
        token = token_;
        votingPeriod = votingPeriod_;
        proposalThreshold = proposalThreshold_;
        quorumBps = quorumBps_;
    }

    /* ==================== PROPOSE ==================== */

    /// @notice Creates a proposal: an arbitrary set of calls executed if it passes.
    /// @dev The proposer's voting power is checked at the PREVIOUS block (can't mint-then-propose).
    function propose(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        string calldata description
    ) external returns (uint256 proposalId) {
        uint256 proposerVotes = token.getPastVotes(msg.sender, block.number - 1);
        if (proposerVotes < proposalThreshold) revert BelowProposalThreshold(proposerVotes, proposalThreshold);
        if (targets.length == 0) revert EmptyProposal();
        if (targets.length != values.length || targets.length != calldatas.length) revert LengthMismatch();
        for (uint256 i = 0; i < targets.length; i++) {
            if (targets[i] == address(0)) revert ZeroTarget();
        }

        proposalId = proposals.length;
        Proposal storage p = proposals.push();
        p.proposer = msg.sender;
        p.snapshotBlock = block.number;
        p.deadline = block.timestamp + votingPeriod;
        for (uint256 i = 0; i < targets.length; i++) {
            p.targets.push(targets[i]);
            p.values.push(values[i]);
            p.calldatas.push(calldatas[i]);
        }
        p.description = description;

        emit ProposalCreated(proposalId, msg.sender, p.deadline);
    }

    /* ==================== VOTE ==================== */

    /// @notice Votes for (`support = true`) or against a proposal.
    /// @dev Weight = the voter's token balance at the proposal's snapshot block — tokens bought
    ///      after the proposal exists add no power.
    function vote(uint256 proposalId, bool support) external {
        Proposal storage p = proposals[proposalId];
        if (block.timestamp > p.deadline) revert VotingEnded(proposalId);
        if (hasVoted[proposalId][msg.sender]) revert AlreadyVoted(proposalId, msg.sender);

        uint256 weight = token.getPastVotes(msg.sender, p.snapshotBlock);
        hasVoted[proposalId][msg.sender] = true;
        if (support) {
            p.forVotes += weight;
        } else {
            p.againstVotes += weight;
        }
        emit VoteCast(proposalId, msg.sender, support, weight);
    }

    /* ==================== EXECUTE / CANCEL ==================== */

    /// @notice Executes all calls of a successful proposal. State flips to executed before the
    ///         external calls (checks-effects-interactions).
    function execute(uint256 proposalId) external {
        if (state(proposalId) != ProposalState.Succeeded) revert ProposalNotSucceeded(proposalId);

        Proposal storage p = proposals[proposalId];
        p.executed = true;
        for (uint256 i = 0; i < p.targets.length; i++) {
            (bool ok,) = p.targets[i].call{value: p.values[i]}(p.calldatas[i]);
            if (!ok) revert ExecutionFailed(i);
        }
        emit ProposalExecuted(proposalId);
    }

    /// @notice The proposer can withdraw a proposal while voting is still open.
    function cancel(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];
        if (msg.sender != p.proposer) revert NotProposer();
        if (block.timestamp > p.deadline) revert VotingEnded(proposalId); // only while active
        p.canceled = true;
        emit ProposalCanceled(proposalId);
    }

    /* ==================== VIEWS ==================== */

    /// @notice The quorum (in whole tokens) required for a proposal to pass.
    function quorum(uint256 proposalId) public view returns (uint256) {
        Proposal storage p = proposals[proposalId];
        return token.getPastTotalSupply(p.snapshotBlock) * quorumBps / 10_000;
    }

    /// @notice Current lifecycle state, derived from time, votes and quorum.
    function state(uint256 proposalId) public view returns (ProposalState) {
        Proposal memory p = proposals[proposalId];
        if (p.executed) return ProposalState.Executed;
        if (p.canceled) return ProposalState.Canceled;
        if (block.timestamp <= p.deadline) return ProposalState.Active;
        if (p.forVotes <= p.againstVotes || p.forVotes < quorum(proposalId)) return ProposalState.Defeated;
        return ProposalState.Succeeded;
    }
}
