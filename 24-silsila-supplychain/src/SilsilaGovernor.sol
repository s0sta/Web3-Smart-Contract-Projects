// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {SilsilaRegistry} from "./SilsilaRegistry.sol";
import {SilsilaCompliance} from "./SilsilaCompliance.sol";
import {SilsilaOrders} from "./SilsilaOrders.sol";
import {SilsilaShipments} from "./SilsilaShipments.sol";
import {SilsilaQuality} from "./SilsilaQuality.sol";
import {SilsilaPayments} from "./SilsilaPayments.sol";
import {SilsilaCargoInsurance} from "./SilsilaCargoInsurance.sol";
import {SilsilaReputation} from "./SilsilaReputation.sol";
import {SilsilaTreasury} from "./SilsilaTreasury.sol";
import {SilsilaOracle} from "./SilsilaOracle.sol";

/// @title SilsilaGovernor
/// @notice The network's parliament: reputation is the vote. Proposals adjust
///         fee splits, insurance premiums and compliance routes against the
///         allowlisted contracts, executed after a timelock.
contract SilsilaGovernor is AccessControl {
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

    uint256 public quorumScore;
    uint256 public reviewPeriod;
    uint256 public votingPeriod;
    uint256 public timelock;

    SilsilaRegistry public immutable registry;
    SilsilaCompliance public immutable compliance;
    SilsilaOrders public immutable orders;
    SilsilaShipments public immutable shipments;
    SilsilaQuality public immutable quality;
    SilsilaPayments public immutable payments;
    SilsilaCargoInsurance public immutable cargoInsurance;
    SilsilaReputation public immutable reputation;
    SilsilaTreasury public immutable treasury;
    SilsilaOracle public immutable oracle;

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
        SilsilaRegistry registry_,
        SilsilaCompliance compliance_,
        SilsilaOrders orders_,
        SilsilaShipments shipments_,
        SilsilaQuality quality_,
        SilsilaPayments payments_,
        SilsilaCargoInsurance cargoInsurance_,
        SilsilaReputation reputation_,
        SilsilaTreasury treasury_,
        SilsilaOracle oracle_,
        uint256 quorumScore_
    ) {
        if (address(registry_) == address(0) || address(compliance_) == address(0) || address(orders_) == address(0) || address(shipments_) == address(0) || address(quality_) == address(0) || address(payments_) == address(0) || address(cargoInsurance_) == address(0) || address(reputation_) == address(0) || address(treasury_) == address(0) || address(oracle_) == address(0)) {
            revert ZeroAddress();
        }
        registry = registry_;
        compliance = compliance_;
        orders = orders_;
        shipments = shipments_;
        quality = quality_;
        payments = payments_;
        cargoInsurance = cargoInsurance_;
        reputation = reputation_;
        treasury = treasury_;
        oracle = oracle_;
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
            target == address(compliance) ||
            target == address(orders) ||
            target == address(shipments) ||
            target == address(quality) ||
            target == address(payments) ||
            target == address(cargoInsurance) ||
            target == address(reputation) ||
            target == address(treasury) ||
            target == address(oracle) ||
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
