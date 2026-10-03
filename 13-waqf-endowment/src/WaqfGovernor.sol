// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {WaqfVault} from "./WaqfVault.sol";
import {BeneficiaryRegistry} from "./BeneficiaryRegistry.sol";

/// @title WaqfGovernor
/// @notice Governance for the endowment: donors vote with their endowed contributions
///         (snapshot at proposal creation), a nazir board confirms, and approved
///         proposals execute after a timelock — always against the allowed targets
///         (the beneficiary registry and the vault's operational fund). The corpus
///         itself is not reachable by any proposal.
contract WaqfGovernor is AccessControl {
    /// @notice The nazir (trustee) board: propose and confirm.
    bytes32 public constant NAZIR_ROLE = keccak256("NAZIR");

    enum ProposalType { AdjustWeight, AddBeneficiary, RemoveBeneficiary, OperationalSpend, Rules }

    struct Proposal {
        ProposalType pType;
        address proposer;
        uint256 snapshotBlock;
        uint256 confirmDeadline;
        uint256 voteStart;
        uint256 voteEnd;
        uint256 executeAfter;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 confirmations;
        bool executed;
        bool canceled;
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
        string description;
    }

    Proposal[] public proposals;

    WaqfVault public immutable vault;
    BeneficiaryRegistry public immutable registry;

    /// @notice Donor voting threshold: a donor needs this many endowed tokens to propose.
    uint256 public proposalThreshold;

    /// @notice Quorum as bps of the corpus at snapshot.
    uint256 public quorumBps;

    /// @notice Timelock between vote end and execution.
    uint256 public timelock;

    /// @notice Proposals are paused while true.
    bool public paused;

    mapping(uint256 proposalId => mapping(address voter => bool)) public hasVoted;
    mapping(uint256 proposalId => mapping(address nazir => bool)) public confirmedBy;

    event ProposalCreated(uint256 indexed proposalId, ProposalType indexed pType, address indexed proposer, string description);
    event Confirmed(uint256 indexed proposalId, address indexed nazir);
    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalCanceled(uint256 indexed proposalId);

    error ZeroAddress();
    error InvalidProposalType();
    error InvalidTargets();
    error ProtocolPaused();
    error BelowProposalThreshold(uint256 power, uint256 threshold);
    error NotInVoting(uint256 proposalId);
    error NotInConfirmation(uint256 proposalId);
    error AlreadyVoted(uint256 proposalId, address voter);
    error AlreadyConfirmed(uint256 proposalId, address nazir);
    error Timelocked(uint256 proposalId, uint256 executeAfter);
    error NotSucceeded(uint256 proposalId);
    error OnlyProposerOrNazir();
    error ConfirmationsInsufficient(uint256 have, uint256 need);
    error CallFailed();

    constructor(
        WaqfVault vault_,
        BeneficiaryRegistry registry_,
        address[] memory nazirs,
        uint256 proposalThreshold_,
        uint256 quorumBps_,
        uint256 timelock_
    ) {
        if (address(vault_) == address(0) || address(registry_) == address(0)) revert ZeroAddress();
        vault = vault_;
        registry = registry_;
        proposalThreshold = proposalThreshold_;
        quorumBps = quorumBps_;
        timelock = timelock_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        for (uint256 i = 0; i < nazirs.length; i++) _grantRole(NAZIR_ROLE, nazirs[i]);
        _grantRole(GUARDIAN_ROLE, msg.sender);
    }

    /* ==================== PROPOSE ==================== */

    function propose(
        ProposalType pType,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        string calldata description
    ) external whenNotPaused returns (uint256 proposalId) {
        uint256 power = vault.getPastContribution(msg.sender, block.number - 1);
        bool isNazir = hasRole(NAZIR_ROLE, msg.sender);
        if (!isNazir && power < proposalThreshold) revert BelowProposalThreshold(power, proposalThreshold);

        _validate(pType, targets, calldatas);

        proposalId = proposals.length;
        Proposal storage p = proposals.push();
        p.pType = pType;
        p.proposer = msg.sender;
        p.snapshotBlock = block.number;
        p.confirmDeadline = block.timestamp + 3 days;
        p.voteStart = block.timestamp + 3 days;
        p.voteEnd = p.voteStart + 7 days;
        p.executeAfter = p.voteEnd + timelock;
        p.targets = targets;
        p.values = values;
        p.calldatas = calldatas;
        p.description = description;
        emit ProposalCreated(proposalId, pType, msg.sender, description);
    }

    function _validate(ProposalType pType, address[] calldata targets, bytes[] calldata calldatas) internal view {
        if (targets.length == 0 || targets.length != calldatas.length) revert InvalidTargets();
        for (uint256 i = 0; i < targets.length; i++) {
            address t = targets[i];
            bool allowed = t == address(registry) || t == address(vault) || t == address(this);
            if (!allowed) revert InvalidTargets();
            if (pType == ProposalType.OperationalSpend) {
                // must call vault.spendOperational
                if (t != address(vault) || calldatas[i].length < 4) revert InvalidTargets();
                if (bytes4(calldatas[i]) != vault.spendOperational.selector) revert InvalidTargets();
            }
            if (pType == ProposalType.AddBeneficiary) {
                if (t != address(registry) || bytes4(calldatas[i]) != registry.addBeneficiary.selector) revert InvalidTargets();
            }
            if (pType == ProposalType.AdjustWeight) {
                if (t != address(registry) || bytes4(calldatas[i]) != registry.setBeneficiaryWeight.selector) revert InvalidTargets();
            }
            if (pType == ProposalType.RemoveBeneficiary) {
                if (t != address(registry) || bytes4(calldatas[i]) != registry.deactivateBeneficiary.selector) revert InvalidTargets();
            }
            if (pType == ProposalType.Rules) {
                if (t != address(this)) revert InvalidTargets();
            }
        }
    }

    /* ==================== CONFIRMATION & VOTING ==================== */

    /// @notice A nazir confirms during the confirmation window (3 days).
    function confirm(uint256 proposalId) external onlyRole(NAZIR_ROLE) {
        Proposal storage p = proposals[proposalId];
        if (block.timestamp > p.confirmDeadline) revert NotInConfirmation(proposalId);
        if (confirmedBy[proposalId][msg.sender]) revert AlreadyConfirmed(proposalId, msg.sender);
        confirmedBy[proposalId][msg.sender] = true;
        p.confirmations += 1;
        emit Confirmed(proposalId, msg.sender);
    }

    /// @notice Donors vote with their contribution at the proposal's snapshot block.
    function vote(uint256 proposalId, bool support) external whenNotPaused {
        Proposal storage p = proposals[proposalId];
        if (block.timestamp < p.voteStart) revert NotInVoting(proposalId);
        if (block.timestamp > p.voteEnd) revert NotInVoting(proposalId);
        if (hasVoted[proposalId][msg.sender]) revert AlreadyVoted(proposalId, msg.sender);

        uint256 weight = vault.getPastContribution(msg.sender, p.snapshotBlock);
        if (weight == 0) revert BelowProposalThreshold(0, 1);

        hasVoted[proposalId][msg.sender] = true;
        if (support) p.forVotes += weight;
        else p.againstVotes += weight;
        emit VoteCast(proposalId, msg.sender, support, weight);
    }

    /* ==================== EXECUTION ==================== */

    function execute(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];
        if (p.executed || p.canceled) revert NotSucceeded(proposalId);
        if (block.timestamp < p.executeAfter) revert Timelocked(proposalId, p.executeAfter);
        if (state(proposalId) != 3) revert NotSucceeded(proposalId); // 3 = Succeeded
        p.executed = true;

        for (uint256 i = 0; i < p.targets.length; i++) {
            (bool ok, bytes memory returndata) = p.targets[i].call{ value: p.values[i] }(p.calldatas[i]);
            if (!ok) {
                // bubble the underlying reason so operators see exactly what failed
                assembly {
                    revert(add(returndata, 0x20), mload(returndata))
                }
            }
        }
        emit ProposalExecuted(proposalId);
    }

    function cancel(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];
        if (p.executed || p.canceled) revert NotSucceeded(proposalId);
        if (msg.sender != p.proposer && !hasRole(NAZIR_ROLE, msg.sender)) revert OnlyProposerOrNazir();
        uint8 st = state(proposalId);
        if (st != 0 && st != 1 && st != 2) revert NotSucceeded(proposalId);
        p.canceled = true;
        emit ProposalCanceled(proposalId);
    }

    /// @dev 0 Confirmation · 1 Voting · 2 Timelock · 3 Succeeded · 4 Executed · 5 Defeated · 6 Canceled
    function state(uint256 proposalId) public view returns (uint8) {
        Proposal storage p = proposals[proposalId];
        if (p.executed) return 4;
        if (p.canceled) return 6;
        if (block.timestamp < p.voteStart) return 0;
        if (block.timestamp <= p.voteEnd) return 1;
        uint256 quorum = (vault.totalCorpus() * quorumBps) / 10_000;
        bool confirmedEnough = p.confirmations >= 2 || hasRole(NAZIR_ROLE, p.proposer);
        if (p.forVotes < quorum || !confirmedEnough) return 5;
        if (block.timestamp < p.executeAfter) return 2;
        return 3;
    }

    function quorum(uint256 proposalId) public view returns (uint256) {
        return (vault.totalCorpus() * quorumBps) / 10_000;
    }

    /* ==================== GUARDIAN & PARAMETERS ==================== */

    function pause() external onlyRole(GUARDIAN_ROLE) { paused = true; }
    function unpause() external onlyRole(GUARDIAN_ROLE) { paused = false; }

    function setQuorumBps(uint256 bps) external onlySelf {
        if (bps > 10_000) revert InvalidProposalType();
        quorumBps = bps;
    }
    function setTimelock(uint256 newTimelock) external onlySelf { timelock = newTimelock; }
    function setProposalThreshold(uint256 threshold) external onlySelf { proposalThreshold = threshold; }

    modifier whenNotPaused() {
        if (paused) revert ProtocolPaused();
        _;
    }
    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlyProposerOrNazir();
        _;
    }
}
