// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";
import {AccessControl} from "./AccessControl.sol";
import {JOPUnitRegistry} from "./JOPUnitRegistry.sol";
import {TreasuryVault} from "./TreasuryVault.sol";
import {Checkpoints} from "./lib/Checkpoints.sol";

/// @title OwnersAssociationGovernor
/// @notice Institutional-grade governance for a jointly owned building — the decision
///         engine of the whole suite.
///
/// @dev Design, mapped to Dubai's jointly owned property regime (Law No. 6 of 2019,
///      RERA practice) and deliberately portable to condominium/HOA laws elsewhere:
///
///      ┌─ Roles ────────────────────────────────────────────────────────────┐
///      │ BOARD (5 seats)  fast-track, register sales, propose emergency     │
///      │ COMPLIANCE        regulatory representative with a binding veto    │
///      │ GUARDIAN          emergency pause + treasury drain                 │
///      └────────────────────────────────────────────────────────────────────┘
///
///      ┌─ Proposal pipeline ────────────────────────────────────────────────┐
///      │ propose → [review] → vote → [timelock] → execute                   │
///      │   · quorum per proposal type (basis points of total building area) │
///      │   · voting weight = owned area + received proxy area, snapshotted  │
///      │   · Emergency proposals skip the timelock (Civil Defence items)    │
///      └────────────────────────────────────────────────────────────────────┘
///
///      The governor itself holds no funds: payments execute into the treasury,
///      unit sales into the registry — separation of powers throughout.
contract OwnersAssociationGovernor is AccessControl {
    using Checkpoints for Checkpoints.Checkpoint[];

    /// @notice The seven proposal types recognised by the association.
    enum ProposalType {
        Budget, // annual service-charge budget & maintenance allocations
        ChargeRate, // changes the per-sqm service-charge rate
        Contract, // awards vendor contracts (cleaning, security, MEP…)
        Rules, // amends association rules and governance parameters
        Election, // elects/removes a board seat
        Payment, // treasury disbursement to a vendor
        Emergency // urgent, board-proposed, timelock-free (Civil Defence)
    }

    /// @notice One proposal with its full lifecycle state.
    struct Proposal {
        ProposalType pType;
        address proposer;
        uint256 snapshotBlock; // voting power is measured at this block
        uint256 reviewStart;
        uint256 voteStart;
        uint256 voteEnd;
        uint256 executeAfter; // timelock release (0 for Emergency)
        uint256 forVotes;
        uint256 againstVotes;
        bool executed;
        bool canceled;
        bool vetoed;
        string vetoNote;
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
        string description;
    }

    /* ==================== IMMUTABLES ==================== */

    /// @notice The unit ledger (ownership, areas, service charges).
    JOPUnitRegistry public immutable registry;

    /// @notice The association treasury.
    TreasuryVault public immutable treasury;

    /* ==================== GOVERNANCE PARAMETERS ==================== */

    /// @notice Minimum owned area (sqm) required to submit a proposal.
    uint256 public proposalThresholdSqm;

    /// @notice How long proposals sit in review before voting opens.
    uint256 public reviewPeriod;

    /// @notice How long voting stays open.
    uint256 public votingPeriod;

    /// @notice Delay between a passed vote and execution (Emergency = 0).
    uint256 public timelock;

    /// @notice Quorum per proposal type: basis points of total building area.
    mapping(ProposalType pType => uint256 bps) public quorumBps;

    /// @notice The five board seats (empty = 0x0).
    address[5] public boardSeats;

    /// @notice Emergency brake: blocks new proposals and voting.
    bool public paused;

    /* ==================== PROPOSALS ==================== */

    Proposal[] public proposals;

    /// @notice proposalId → voter → voted?
    mapping(uint256 proposalId => mapping(address voter => bool)) public hasVoted;

    /* ==================== DELEGATION (PROXY VOTING) ==================== */

    /// @notice delegator → delegatee.
    mapping(address delegator => address delegatee) public delegatee;

    /// @notice delegator → delegation expiry timestamp.
    mapping(address delegator => uint256 expiry) public delegationExpiry;

    /// @notice Proxy power received by each delegatee, snapshotted per block.
    mapping(address delegatee => Checkpoints.Checkpoint[]) private _receivedPower;

    /* ==================== EVENTS ==================== */

    event ProposalCreated(uint256 indexed proposalId, uint8 indexed pType, address indexed proposer);
    event ProposalFastTracked(uint256 indexed proposalId, address indexed by);
    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight);
    event ProposalVetoed(uint256 indexed proposalId, address indexed by, string note);
    event ProposalCanceled(uint256 indexed proposalId, address indexed by);
    event ProposalExecuted(uint256 indexed proposalId);
    event BoardSeatSet(uint256 indexed seat, address indexed member);
    event DelegationChanged(address indexed delegator, address indexed delegatee, uint256 expiry);
    event UnitSaleRegistered(uint256 indexed unitId, address indexed from, address indexed to);
    event ParameterUpdated(bytes32 indexed key, uint256 value);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    /* ==================== ERRORS ==================== */

    error BelowProposalThreshold(uint256 power, uint256 threshold);
    error InvalidProposalType();
    error InvalidTargets();
    error InvalidElectionCalldata();
    error NotBoardSeat(uint256 seat);
    error InvalidSeat();
    error EmptyProposal();
    error LengthMismatch();
    error NotInReview(uint256 proposalId);
    error NotInVoting(uint256 proposalId);
    error AlreadyVoted(uint256 proposalId, address voter);
    error NotProposerOrBoard();
    error NotSucceeded(uint256 proposalId);
    error Timelocked(uint256 proposalId, uint256 executeAfter);
    error Vetoed(uint256 proposalId);
    error ExpiredDelegation();
    error ZeroAddress();
    error ProtocolPaused();
    error ProposalExists();
    error ExecutionFailed(uint256 index);
    error InvalidPaymentTarget();

    /* ==================== MODIFIERS ==================== */

    modifier whenNotPaused() {
        if (paused) revert ProtocolPaused();
        _;
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) revert InvalidTargets();
        _;
    }

    modifier onlyBoard() {
        if (!hasRole(BOARD_MEMBER_ROLE, msg.sender)) revert InvalidTargets();
        _;
    }

    /* ==================== LIFECYCLE ==================== */

    constructor(
        JOPUnitRegistry registry_,
        TreasuryVault treasury_,
        address complianceOfficer,
        address guardian,
        address[] memory initialBoard,
        uint256 reviewPeriod_,
        uint256 votingPeriod_,
        uint256 timelock_
    ) {
        if (address(registry_) == address(0) || address(treasury_) == address(0)) {
            revert ZeroAddress();
        }
        registry = registry_;
        treasury = treasury_;

        // Statutory defaults (periods are deployment-configurable; quorums
        // and the threshold are governance-settable via Rules proposals).
        proposalThresholdSqm = 50; // a 50-sqm unit can propose
        reviewPeriod = reviewPeriod_;
        votingPeriod = votingPeriod_;
        timelock = timelock_;

        quorumBps[ProposalType.Budget] = 2000; // 20% of area
        quorumBps[ProposalType.ChargeRate] = 3000; // 30%
        quorumBps[ProposalType.Contract] = 2000; // 20%
        quorumBps[ProposalType.Rules] = 3000; // 30%
        quorumBps[ProposalType.Election] = 2000; // 20%
        quorumBps[ProposalType.Payment] = 1500; // 15%
        quorumBps[ProposalType.Emergency] = 1500; // 15%

        if (initialBoard.length > 5) revert InvalidSeat();
        for (uint256 i = 0; i < initialBoard.length; i++) {
            if (initialBoard[i] == address(0)) revert ZeroAddress();
            boardSeats[i] = initialBoard[i];
            _grantRole(BOARD_MEMBER_ROLE, initialBoard[i]);
            emit BoardSeatSet(i, initialBoard[i]);
        }
        if (complianceOfficer != address(0)) _grantRole(COMPLIANCE_ROLE, complianceOfficer);
        if (guardian != address(0)) _grantRole(GUARDIAN_ROLE, guardian);
    }

    /* ==================== PROPOSE ==================== */

    /// @notice Submits a proposal into the review stage.
    /// @dev Threshold power is measured at the PREVIOUS block (no mint-then-propose).
    ///      Target allowlist: the registry, the treasury, or the governor itself —
    ///      arbitrary external calls are structurally impossible. Per-type validation
    ///      guarantees Elections elect board members and Payments pay the treasury's vendors.
    function propose(
        uint8 pType_,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        string calldata description
    ) external whenNotPaused returns (uint256 proposalId) {
        ProposalType pType = _validateType(pType_);
        if (targets.length == 0) revert EmptyProposal();
        if (targets.length != values.length || targets.length != calldatas.length) revert LengthMismatch();

        uint256 power = registry.getPastOwnerArea(msg.sender, block.number - 1);
        bool board = hasRole(BOARD_MEMBER_ROLE, msg.sender);
        if (power < proposalThresholdSqm && !board) revert BelowProposalThreshold(power, proposalThresholdSqm);
        if (pType == ProposalType.Emergency && !board) revert InvalidProposalType();

        _validateTargets(pType, targets, values, calldatas);

        proposalId = proposals.length;
        Proposal storage p = proposals.push();
        p.pType = pType;
        p.proposer = msg.sender;
        p.snapshotBlock = block.number;
        p.reviewStart = block.timestamp;
        p.voteStart = block.timestamp + reviewPeriod;
        p.voteEnd = p.voteStart + votingPeriod;
        p.executeAfter = pType == ProposalType.Emergency ? 0 : p.voteEnd + timelock;
        // element-wise copies: the legacy codegen cannot copy dynamic calldata arrays
        // (bytes[]) into storage in one assignment
        for (uint256 i = 0; i < targets.length; i++) {
            p.targets.push(targets[i]);
            p.values.push(values[i]);
            p.calldatas.push(calldatas[i]);
        }
        p.description = description;

        emit ProposalCreated(proposalId, pType_, msg.sender);
    }

    /// @dev Every target must be a known association contract; per-type rules narrow it further.
    ///      ETH values are only ever attached to treasury calls.
    function _validateTargets(
        ProposalType pType,
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas
    ) internal view {
        for (uint256 i = 0; i < targets.length; i++) {
            address t = targets[i];
            if (t != address(registry) && t != address(treasury) && t != address(this)) revert InvalidTargets();
            if (t != address(treasury) && values[i] != 0) revert InvalidTargets();
            if (pType == ProposalType.Payment && t != address(treasury)) revert InvalidPaymentTarget();
            if (pType == ProposalType.ChargeRate && (t != address(registry) || calldatas[i].length < 4 || bytes4(calldatas[i]) != registry.setAnnualChargePerSqm.selector)) {
                revert InvalidTargets();
            }
            if (pType == ProposalType.Election) {
                if (t != address(this) || calldatas[i].length < 4 || bytes4(calldatas[i]) != this.setBoardMember.selector) {
                    revert InvalidElectionCalldata();
                }
            }
        }
    }

    function _validateType(uint8 t) internal pure returns (ProposalType) {
        if (t > uint8(ProposalType.Emergency)) revert InvalidProposalType();
        return ProposalType(t);
    }

    /* ==================== REVIEW ==================== */

    /// @notice The board may fast-track a proposal: voting opens immediately.
    function fastTrack(uint256 proposalId) external onlyBoard {
        Proposal storage p = proposals[proposalId];
        if (p.executed || p.canceled || p.vetoed) revert InvalidTargets();
        if (block.timestamp >= p.voteStart) revert NotInReview(proposalId);
        p.voteStart = block.timestamp;
        p.voteEnd = block.timestamp + votingPeriod;
        if (p.pType != ProposalType.Emergency) p.executeAfter = p.voteEnd + timelock;
        emit ProposalFastTracked(proposalId, msg.sender);
    }

    /// @notice The compliance officer vetoes a proposal with a recorded reason.
    /// @dev The veto is binding and permanent — the regulatory backstop.
    function veto(uint256 proposalId, string calldata note) external onlyRole(COMPLIANCE_ROLE) {
        Proposal storage p = proposals[proposalId];
        if (p.executed || p.canceled || p.vetoed) revert InvalidTargets();
        p.vetoed = true;
        p.vetoNote = note;
        emit ProposalVetoed(proposalId, msg.sender, note);
    }

    /* ==================== VOTE ==================== */

    /// @notice Casts a vote. Weight = owned area + received proxy area at the snapshot.
    function vote(uint256 proposalId, bool support) external whenNotPaused {
        Proposal storage p = proposals[proposalId];
        if (block.timestamp < p.voteStart) revert NotInVoting(proposalId);
        if (block.timestamp > p.voteEnd) revert NotInVoting(proposalId);
        if (p.vetoed || p.canceled) revert InvalidTargets();
        if (hasVoted[proposalId][msg.sender]) revert AlreadyVoted(proposalId, msg.sender);

        uint256 weight = votingPowerAt(msg.sender, p.snapshotBlock);
        hasVoted[proposalId][msg.sender] = true;
        if (support) {
            p.forVotes += weight;
        } else {
            p.againstVotes += weight;
        }
        emit VoteCast(proposalId, msg.sender, support, weight);
    }

    /// @notice Current voting weight of `account`: owned area + live proxy power.
    function votingPower(address account) public view returns (uint256) {
        return registry.ownerAreaSqm(account) + _receivedPower[account].latest();
    }

    /// @notice Voting weight at a past block (the snapshot primitive).
    function votingPowerAt(address account, uint256 blockNumber) public view returns (uint256) {
        return registry.getPastOwnerArea(account, blockNumber) + _receivedPower[account].lookup(blockNumber);
    }

    /* ==================== DELEGATION ==================== */

    /// @notice Delegates proxy voting power to `to` until `expiresAt`.
    /// @dev The delegator's full current area moves as proxy power; on expiry it lapses
    ///      (enforced lazily by vote-weight checks and refreshed by re-delegation).
    function delegate(address to, uint256 expiresAt) external whenNotPaused {
        if (to == address(0)) revert ZeroAddress();
        if (expiresAt <= block.timestamp) revert ExpiredDelegation();
        _removeDelegation(msg.sender);
        delegatee[msg.sender] = to;
        delegationExpiry[msg.sender] = expiresAt;
        uint256 area = registry.ownerAreaSqm(msg.sender);
        _receivedPower[to].write(_receivedPower[to].latest(), _receivedPower[to].latest() + area);
        emit DelegationChanged(msg.sender, to, expiresAt);
    }

    /// @notice Revokes the caller's active delegation.
    function revokeDelegation() external {
        _removeDelegation(msg.sender);
    }

    function _removeDelegation(address delegator) internal {
        address to = delegatee[delegator];
        if (to == address(0)) return;
        uint256 area = registry.ownerAreaSqm(delegator);
        _receivedPower[to].write(_receivedPower[to].latest(), _receivedPower[to].latest() - area);
        delete delegatee[delegator];
        delete delegationExpiry[delegator];
        emit DelegationChanged(delegator, address(0), 0);
    }

    /// @notice True when `account`'s current delegation is still live.
    function delegationActive(address account) public view returns (bool) {
        return delegatee[account] != address(0) && delegationExpiry[account] > block.timestamp;
    }

    /* ==================== EXECUTE / CANCEL ==================== */

    /// @notice Executes all calls of a passed proposal (checks-effects-interactions:
    ///         the executed flag flips before any external call).
    function execute(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];
        // executable exactly in the Succeeded state (and during the Timelock window,
        // where the timelock gate below turns the attempt into Timelocked)
        uint8 st = state(proposalId);
        if (st != 2 && st != 3) revert NotSucceeded(proposalId);
        if (p.pType != ProposalType.Emergency && block.timestamp < p.executeAfter) {
            revert Timelocked(proposalId, p.executeAfter);
        }
        p.executed = true;
        for (uint256 i = 0; i < p.targets.length; i++) {
            if (p.values[i] != 0 && p.targets[i] != address(treasury)) revert InvalidTargets();
            (bool ok, ) = p.targets[i].call{value: p.values[i]}(p.calldatas[i]);
            if (!ok) revert ExecutionFailed(i);
        }
        emit ProposalExecuted(proposalId);
    }

    /// @notice The proposer (or the board) cancels a proposal before it passes.
    function cancel(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];
        if (p.executed || p.canceled || p.vetoed) revert InvalidTargets();
        if (msg.sender != p.proposer && !hasRole(BOARD_MEMBER_ROLE, msg.sender)) revert NotProposerOrBoard();
        if (block.timestamp > p.voteEnd) revert NotInVoting(proposalId);
        p.canceled = true;
        emit ProposalCanceled(proposalId, msg.sender);
    }

    /* ==================== STATE & QUORUM ==================== */

    /// @notice Proposal lifecycle state:
    ///         0 Pending(review) · 1 Active(voting) · 2 Timelock · 3 Succeeded ·
    ///         4 Executed · 5 Defeated · 6 Canceled · 7 Vetoed
    function state(uint256 proposalId) public view returns (uint8) {
        Proposal storage p = proposals[proposalId];
        if (p.executed) return 4;
        if (p.vetoed) return 7;
        if (p.canceled) return 6;
        if (block.timestamp < p.voteStart) return 0;
        if (block.timestamp <= p.voteEnd) return 1;
        if (p.forVotes <= p.againstVotes || p.forVotes < quorum(proposalId)) return 5;
        if (p.pType == ProposalType.Emergency) return 3;
        if (block.timestamp < p.executeAfter) return 2;
        return 3;
    }

    /// @notice The quorum (in sqm) required for a proposal to pass.
    function quorum(uint256 proposalId) public view returns (uint256) {
        Proposal storage p = proposals[proposalId];
        return (registry.totalAreaSqm() * quorumBps[p.pType]) / 10_000;
    }

    /* ==================== GOVERNANCE PARAMETER SETTERS (onlySelf) ==================== */

    /// @dev All of the below are callable only by the governor itself, i.e. exclusively
    ///      through a passed Rules/ChargeRate/… proposal executing these selectors.

    function setQuorum(uint8 pType_, uint256 bps) external onlySelf {
        ProposalType pType = _validateType(pType_);
        if (bps > 10_000) revert InvalidProposalType();
        quorumBps[pType] = bps;
        emit ParameterUpdated(keccak256("quorum"), bps);
    }

    function setReviewPeriod(uint256 seconds_) external onlySelf {
        reviewPeriod = seconds_;
        emit ParameterUpdated(keccak256("reviewPeriod"), seconds_);
    }

    function setVotingPeriod(uint256 seconds_) external onlySelf {
        votingPeriod = seconds_;
        emit ParameterUpdated(keccak256("votingPeriod"), seconds_);
    }

    function setTimelock(uint256 seconds_) external onlySelf {
        timelock = seconds_;
        emit ParameterUpdated(keccak256("timelock"), seconds_);
    }

    function setProposalThreshold(uint256 sqm) external onlySelf {
        proposalThresholdSqm = sqm;
        emit ParameterUpdated(keccak256("threshold"), sqm);
    }

    function setBoardMember(address member, uint256 seat) external onlySelf {
        if (seat >= 5) revert InvalidSeat();
        if (member == address(0)) revert ZeroAddress();
        address previous = boardSeats[seat];
        if (previous != address(0)) {
            _revokeRole(BOARD_MEMBER_ROLE, previous);
        }
        boardSeats[seat] = member;
        _grantRole(BOARD_MEMBER_ROLE, member);
        emit BoardSeatSet(seat, member);
    }

    /// @notice Governance-approved route to re-register a unit sale (or the board directly).
    function registerUnitSale(uint256 unitId, address newOwner) external {
        bool board = hasRole(BOARD_MEMBER_ROLE, msg.sender);
        if (msg.sender != address(this) && !board) revert NotProposerOrBoard();
        JOPUnitRegistry reg = registry;

        // keep proxy power consistent across the ownership change
        (uint256 unitArea, address previous, , ) = reg.units(unitId);
        if (previous != address(0) && delegationActive(previous)) {
            address to = delegatee[previous];
            _receivedPower[to].write(_receivedPower[to].latest(), _receivedPower[to].latest() - unitArea);
        }
        reg.registerSale(unitId, newOwner);
        if (delegationActive(newOwner)) {
            address to = delegatee[newOwner];
            _receivedPower[to].write(_receivedPower[to].latest(), _receivedPower[to].latest() + unitArea);
        }
        emit UnitSaleRegistered(unitId, previous, newOwner);
    }

    /* ==================== EMERGENCY ==================== */

    /// @notice Guardian emergency brake: blocks new proposals and voting.
    function pause() external onlyRole(GUARDIAN_ROLE) {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyRole(GUARDIAN_ROLE) {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Guardian may drain the treasury in a catastrophic scenario.
    function emergencyDrainTreasury(address to) external onlyRole(GUARDIAN_ROLE) {
        treasury.emergencyDrain(to);
    }
}
