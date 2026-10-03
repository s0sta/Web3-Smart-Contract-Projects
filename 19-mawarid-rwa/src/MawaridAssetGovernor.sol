// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {MawaridShares} from "./MawaridShares.sol";
import {MawaridAssetRegistry} from "./MawaridAssetRegistry.sol";
import {MawaridRentalDistributor} from "./MawaridRentalDistributor.sol";
import {MawaridTreasury} from "./MawaridTreasury.sol";

/// @title MawaridAssetGovernor
/// @notice Per-asset governance: share holders vote with their snapshot balances on
///         proposals that control their asset (appraisals, reserves, manager changes,
///         payouts and rule changes), with per-type quorums and a timelock.
contract MawaridAssetGovernor is AccessControl {
    /// @notice The platform manager may propose and execute urgent items.
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER");

    enum ProposalType { Appraise, SetReserve, ManagerChange, Payout, Rules }

    /// @notice One proposal (scalars only — execution arrays are stored separately).
    struct Proposal {
        ProposalType pType;
        address proposer;
        uint256 assetId;
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

    /// @notice Quorum per proposal type (bps of the asset's issued shares).
    mapping(ProposalType => uint256) public quorumBps;

    uint256 public reviewPeriod;
    uint256 public votingPeriod;
    uint256 public timelock;

    MawaridShares public immutable shares;
    MawaridAssetRegistry public immutable registry;
    MawaridRentalDistributor public immutable distributor;
    MawaridTreasury public immutable treasury;

    bool public paused;

    event ProposalCreated(uint256 indexed proposalId, uint256 indexed assetId, ProposalType indexed pType, address proposer, string description);
    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalCanceled(uint256 indexed proposalId);
    event Paused(bool paused);

    error ZeroAddress();
    error InvalidProposalType();
    error InvalidTargets();
    error ProtocolPaused();
    error UnknownAsset(uint256 assetId);
    error NotInVoting(uint256 proposalId);
    error AlreadyVoted(uint256 proposalId, address voter);
    error NotSucceeded(uint256 proposalId);
    error Timelocked(uint256 proposalId, uint256 executeAfter);
    error OnlyProposerOrManager();
    error CallFailed();

    constructor(
        MawaridShares shares_,
        MawaridAssetRegistry registry_,
        MawaridRentalDistributor distributor_,
        MawaridTreasury treasury_
    ) {
        if (address(shares_) == address(0) || address(registry_) == address(0) || address(distributor_) == address(0) || address(treasury_) == address(0)) {
            revert ZeroAddress();
        }
        shares = shares_;
        registry = registry_;
        distributor = distributor_;
        treasury = treasury_;

        reviewPeriod = 2 days;
        votingPeriod = 5 days;
        timelock = 2 days;

        quorumBps[ProposalType.Appraise] = 1000; // 10%
        quorumBps[ProposalType.SetReserve] = 2000; // 20%
        quorumBps[ProposalType.ManagerChange] = 3000; // 30%
        quorumBps[ProposalType.Payout] = 2000; // 20%
        quorumBps[ProposalType.Rules] = 3000; // 30%

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);
    }

    modifier whenNotPaused() {
        if (paused) revert ProtocolPaused();
        _;
    }

    function _issuedShares(uint256 assetId) internal view returns (uint256) {
        ( , , , , uint256 issuedShares, , , ) = registry.assets(assetId);
        return issuedShares;
    }

    function _totalShares(uint256 assetId) internal view returns (uint256) {
        ( , , , uint256 totalShares, , , , ) = registry.assets(assetId);
        return totalShares;
    }

    /* ==================== PROPOSE ==================== */

    function propose(
        ProposalType pType,
        uint256 assetId,
        address target,
        uint256 value,
        bytes calldata calldataBytes,
        string calldata description
    ) external whenNotPaused returns (uint256 proposalId) {
        if (_totalShares(assetId) == 0) revert UnknownAsset(assetId);
        if (uint8(pType) > uint8(ProposalType.Rules)) revert InvalidProposalType();
        _validate(pType, target, calldataBytes);

        proposalId = proposals.length;
        proposals.push();
        Proposal storage p = proposals[proposalId];
        p.pType = pType;
        p.proposer = msg.sender;
        p.assetId = assetId;
        p.snapshotBlock = block.number;
        p.voteStart = block.timestamp + reviewPeriod;
        p.voteEnd = p.voteStart + votingPeriod;
        p.executeAfter = p.voteEnd + timelock;
        p.target = target;
        p.value = value;
        p.calldataBytes = calldataBytes;
        p.description = description;
        emit ProposalCreated(proposalId, assetId, pType, msg.sender, description);
    }

    function _validate(ProposalType pType, address target, bytes calldata calldataBytes) internal view {
        bool allowed =
            target == address(registry) ||
            target == address(distributor) ||
            target == address(treasury) ||
            target == address(this);
        if (!allowed) revert InvalidTargets();
        if (pType == ProposalType.Appraise) {
            if (target != address(registry) || bytes4(calldataBytes) != registry.appraise.selector) revert InvalidTargets();
        }
        if (pType == ProposalType.SetReserve) {
            if (target != address(distributor) || bytes4(calldataBytes) != distributor.setMaintenanceReserveBps.selector) revert InvalidTargets();
        }
        if (pType == ProposalType.Payout) {
            if (target != address(treasury) || bytes4(calldataBytes) != treasury.payVendor.selector) revert InvalidTargets();
        }
        if (pType == ProposalType.ManagerChange) {
            if (target != address(this) || bytes4(calldataBytes) != this.setManager.selector) revert InvalidTargets();
        }
        if (pType == ProposalType.Rules) {
            if (target != address(this)) revert InvalidTargets();
        }
    }

    /* ==================== VOTING ==================== */

    function vote(uint256 proposalId, bool support) external whenNotPaused {
        Proposal storage p = proposals[proposalId];
        if (block.timestamp < p.voteStart || block.timestamp > p.voteEnd) revert NotInVoting(proposalId);
        if (hasVoted[proposalId][msg.sender]) revert AlreadyVoted(proposalId, msg.sender);

        uint256 weight = shares.getPastBalance(msg.sender, p.snapshotBlock);
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
        if (state(proposalId) != 3) revert NotSucceeded(proposalId); // 3 = Succeeded
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
        if (msg.sender != p.proposer && !hasRole(MANAGER_ROLE, msg.sender)) revert OnlyProposerOrManager();
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
        uint256 quorum = (_issuedShares(p.assetId) * quorumBps[p.pType]) / 10_000;
        if (p.forVotes < quorum || p.forVotes <= p.againstVotes) return 5;
        if (block.timestamp < p.executeAfter) return 2;
        return 3;
    }

    function quorum(uint256 proposalId) public view returns (uint256) {
        Proposal storage p = proposals[proposalId];
        return (_issuedShares(p.assetId) * quorumBps[p.pType]) / 10_000;
    }

    /* ==================== PARAMETERS & GUARDIAN ==================== */

    function setQuorumBps(ProposalType pType, uint256 bps) external onlySelf {
        if (bps > 10_000) revert InvalidProposalType();
        quorumBps[pType] = bps;
    }

    function setReviewPeriod(uint256 period) external onlySelf { reviewPeriod = period; }
    function setVotingPeriod(uint256 period) external onlySelf { votingPeriod = period; }
    function setTimelock(uint256 t) external onlySelf { timelock = t; }

    /// @notice Records a manager appointment (called via a ManagerChange proposal).
    function setManager(address newManager) external onlySelf {
        if (newManager == address(0)) revert ZeroAddress();
        _grantRole(MANAGER_ROLE, newManager);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        paused = true;
        emit Paused(true);
    }

    function unpause() external onlyRole(GUARDIAN_ROLE) {
        paused = false;
        emit Paused(false);
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlyProposerOrManager();
        _;
    }
}
