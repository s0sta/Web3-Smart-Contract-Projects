// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {TamweelVault} from "./TamweelVault.sol";
import {TamweelRateModel} from "./TamweelRateModel.sol";
import {TamweelMarkets} from "./TamweelMarkets.sol";
import {TamweelLoans} from "./TamweelLoans.sol";
import {TamweelCompliance} from "./TamweelCompliance.sol";

/// @title TamweelGovernor
/// @notice The bank's parliament: depositors vote with their vault shares
///         (snapshot at proposal creation) on parameter changes — rate curves,
///         market LTVs, loan pricing, compliance bands — executed after a timelock
///         against the allowlisted contracts only.
contract TamweelGovernor is AccessControl {
    /// @notice The operator may propose urgent parameter changes.
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

    /// @notice Quorum as bps of the vault's total shares.
    uint256 public quorumBps;

    uint256 public reviewPeriod;
    uint256 public votingPeriod;
    uint256 public timelock;

    TamweelVault public immutable vault;
    TamweelRateModel public immutable rateModel;
    TamweelMarkets public immutable markets;
    TamweelLoans public immutable loans;
    TamweelCompliance public immutable compliance;

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
        TamweelVault vault_,
        TamweelRateModel rateModel_,
        TamweelMarkets markets_,
        TamweelLoans loans_,
        TamweelCompliance compliance_,
        uint256 quorumBps_
    ) {
        if (address(vault_) == address(0) || address(rateModel_) == address(0) || address(markets_) == address(0) || address(loans_) == address(0) || address(compliance_) == address(0)) {
            revert ZeroAddress();
        }
        vault = vault_;
        rateModel = rateModel_;
        markets = markets_;
        loans = loans_;
        compliance = compliance_;
        quorumBps = quorumBps_;
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
            target == address(rateModel) ||
            target == address(markets) ||
            target == address(loans) ||
            target == address(compliance) ||
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

        uint256 weight = vault.getPastShares(msg.sender, p.snapshotBlock);
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
        uint256 quorum = (vault.totalSupply() * quorumBps) / 10_000;
        if (p.forVotes < quorum || p.forVotes <= p.againstVotes) return 5;
        if (block.timestamp < p.executeAfter) return 2;
        return 3;
    }

    function quorum() public view returns (uint256) {
        return (vault.totalSupply() * quorumBps) / 10_000;
    }

    /* ==================== PARAMETERS & GUARDIAN ==================== */

    function setQuorumBps(uint256 bps) external onlySelf {
        if (bps > 10_000) revert InvalidTargets();
        quorumBps = bps;
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
