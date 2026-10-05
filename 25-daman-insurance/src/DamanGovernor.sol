// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {DamanPolicies} from "./DamanPolicies.sol";
import {DamanPricing, DamanLines} from "./DamanPricing.sol";
import {DamanPremiums} from "./DamanPremiums.sol";
import {DamanClaims} from "./DamanClaims.sol";
import {DamanParametric} from "./DamanParametric.sol";
import {DamanReinsurance} from "./DamanReinsurance.sol";
import {DamanSurplus} from "./DamanSurplus.sol";
import {DamanTreasury} from "./DamanTreasury.sol";
import {DamanOracle} from "./DamanOracle.sol";
import {DamanRegistry} from "./DamanRegistry.sol";
import {Checkpoints} from "./lib/Checkpoints.sol";

/// @title DamanGovernor
/// @notice The mutual's parliament: policyholders vote with the premium value
///         they contributed (snapshot at proposal creation). Proposals adjust
///         rates, limits and parameters against the allowlisted contracts.
contract DamanGovernor is AccessControl {
    using Checkpoints for Checkpoints.Checkpoint[];

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

    /// @notice Premium contributions per holder (checkpointed for voting).
    mapping(address holder => uint256) public premiumContributed;
    mapping(address holder => Checkpoints.Checkpoint[]) private _contributions;

    uint256 public quorumBps;
    uint256 public reviewPeriod;
    uint256 public votingPeriod;
    uint256 public timelock;

    DamanPolicies public immutable policies;
    DamanPricing public immutable pricing;
    DamanPremiums public immutable premiums;
    DamanClaims public immutable claims;
    DamanParametric public immutable parametric;
    DamanReinsurance public immutable reinsurance;
    DamanSurplus public immutable surplus;
    DamanTreasury public immutable treasury;
    DamanOracle public immutable oracle;
    DamanRegistry public immutable registry;

    bool public paused;

    event PremiumRecorded(address indexed holder, uint256 amount);
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
        DamanPolicies policies_,
        DamanPricing pricing_,
        DamanPremiums premiums_,
        DamanClaims claims_,
        DamanParametric parametric_,
        DamanReinsurance reinsurance_,
        DamanSurplus surplus_,
        DamanTreasury treasury_,
        DamanOracle oracle_,
        DamanRegistry registry_,
        uint256 quorumBps_
    ) {
        if (address(policies_) == address(0) || address(pricing_) == address(0) || address(premiums_) == address(0) || address(claims_) == address(0) || address(parametric_) == address(0) || address(reinsurance_) == address(0) || address(surplus_) == address(0) || address(treasury_) == address(0) || address(oracle_) == address(0) || address(registry_) == address(0)) {
            revert ZeroAddress();
        }
        policies = policies_;
        pricing = pricing_;
        premiums = premiums_;
        claims = claims_;
        parametric = parametric_;
        reinsurance = reinsurance_;
        surplus = surplus_;
        treasury = treasury_;
        oracle = oracle_;
        registry = registry_;
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

    /* ==================== CONTRIBUTIONS ==================== */

    /// @notice The policies desk records each premium paid.
    function recordPremium(address holder, uint256 amount) external {
        if (msg.sender != address(policies) && msg.sender != address(parametric) && !hasRole(OPERATOR_ROLE, msg.sender)) revert OnlyProposerOrOperator();
        premiumContributed[holder] += amount;
        _contributions[holder].write(_contributions[holder].latest(), premiumContributed[holder]);
        emit PremiumRecorded(holder, amount);
    }

    function getPastContribution(address holder, uint256 blockNumber) external view returns (uint256) {
        return _contributions[holder].lookup(blockNumber);
    }

    /* ==================== PROPOSE ==================== */

    function propose(
        address target,
        uint256 value,
        bytes calldata calldataBytes,
        string calldata description
    ) external whenNotPaused returns (uint256 proposalId) {
        bool allowed =
            target == address(pricing) ||
            target == address(policies) ||
            target == address(premiums) ||
            target == address(claims) ||
            target == address(parametric) ||
            target == address(reinsurance) ||
            target == address(surplus) ||
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

        uint256 weight = _contributions[msg.sender].lookup(p.snapshotBlock);
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
        uint256 q = (premiums.totalPremiumsSum() * quorumBps) / 10_000;
        if (p.forVotes < q || p.forVotes <= p.againstVotes) return 5;
        if (block.timestamp < p.executeAfter) return 2;
        return 3;
    }

    function quorum() public view returns (uint256) {
        return (premiums.totalPremiumsSum() * quorumBps) / 10_000;
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
