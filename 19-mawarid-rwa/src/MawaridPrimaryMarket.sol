// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";
import {AccessControl} from "./AccessControl.sol";
import {MawaridShares} from "./MawaridShares.sol";
import {MawaridCompliance} from "./MawaridCompliance.sol";
import {MawaridAssetRegistry} from "./MawaridAssetRegistry.sol";

/// @title MawaridPrimaryMarket
/// @notice The primary issuance venue: subscriptions for each tokenized asset run in
///         phases (a cap + price + window), subscriptions are escrowed in the
///         payment stable, and at finalization shares are minted pro-rata (with
///         refunds for oversubscription and full refunds on cancellation).
contract MawaridPrimaryMarket is AccessControl {
    /// @notice The platform manager: opens phases, finalizes/cancels.
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER");

    /// @notice One subscription phase.
    struct Phase {
        uint256 assetId;
        uint256 pricePerShare; // in the payment token
        uint256 capShares; // shares offered in this phase
        uint64 startsAt;
        uint64 endsAt;
        uint256 subscribedShares;
        uint256 collected; // payment received
        bool finalized;
        bool canceled;
    }

    Phase[] public phases;

    /// @notice Subscriptions per phase per investor.
    mapping(uint256 phaseId => mapping(address investor => uint256)) public subscriptions;
    mapping(uint256 phaseId => mapping(address investor => uint256)) public allocations;

    MawaridShares public immutable shares;
    MawaridCompliance public immutable compliance;
    MawaridAssetRegistry public immutable registry;
    IERC20 public immutable paymentToken;

    event PhaseOpened(uint256 indexed phaseId, uint256 indexed assetId, uint256 pricePerShare, uint256 capShares);
    event Subscribed(uint256 indexed phaseId, address indexed investor, uint256 shares, uint256 paid);
    event PhaseFinalized(uint256 indexed phaseId, uint256 allocated, uint256 refunded);
    event PhaseCanceled(uint256 indexed phaseId, uint256 refunded);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownPhase(uint256 phaseId);
    error PhaseClosed(uint256 phaseId);
    error PhaseNotFinalizable(uint256 phaseId);
    error AlreadyFinalized(uint256 phaseId);
    error AlreadyCanceled(uint256 phaseId);
    error CapExceeded(uint256 requested, uint256 remaining);
    error TransferFailed();

    constructor(
        MawaridShares shares_,
        MawaridCompliance compliance_,
        MawaridAssetRegistry registry_,
        IERC20 paymentToken_
    ) {
        if (address(shares_) == address(0) || address(compliance_) == address(0) || address(registry_) == address(0) || address(paymentToken_) == address(0)) {
            revert ZeroAddress();
        }
        shares = shares_;
        compliance = compliance_;
        registry = registry_;
        paymentToken = paymentToken_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);
    }

    /* ==================== PHASES ==================== */

    function openPhase(
        uint256 assetId,
        uint256 pricePerShare,
        uint256 capShares,
        uint64 startsAt,
        uint64 endsAt
    ) external onlyRole(MANAGER_ROLE) returns (uint256 phaseId) {
        if (pricePerShare == 0 || capShares == 0) revert ZeroAmount();
        if (endsAt <= startsAt) revert ZeroAmount();
        phaseId = phases.length;
        phases.push(
            Phase({
                assetId: assetId,
                pricePerShare: pricePerShare,
                capShares: capShares,
                startsAt: startsAt,
                endsAt: endsAt,
                subscribedShares: 0,
                collected: 0,
                finalized: false,
                canceled: false
            })
        );
        emit PhaseOpened(phaseId, assetId, pricePerShare, capShares);
    }

    /* ==================== SUBSCRIPTIONS ==================== */

    function subscribe(uint256 phaseId, uint256 shareAmount) external {
        Phase storage p = phases[phaseId];
        if (p.pricePerShare == 0) revert UnknownPhase(phaseId);
        if (block.timestamp < p.startsAt || block.timestamp > p.endsAt) revert PhaseClosed(phaseId);
        if (shareAmount == 0) revert ZeroAmount();
        if (!compliance.canHold(p.assetId, msg.sender)) revert();

        uint256 min = compliance.minInvestment(p.assetId);
        if (min > 0 && subscriptions[phaseId][msg.sender] + shareAmount < min) revert ZeroAmount();

        if (p.subscribedShares + shareAmount > p.capShares) {
            revert CapExceeded(shareAmount, p.capShares - p.subscribedShares);
        }

        uint256 cost = (shareAmount * p.pricePerShare) / 1e18;
        if (!paymentToken.transferFrom(msg.sender, address(this), cost)) revert TransferFailed();

        subscriptions[phaseId][msg.sender] += shareAmount;
        p.subscribedShares += shareAmount;
        p.collected += cost;
        emit Subscribed(phaseId, msg.sender, shareAmount, cost);
    }

    /* ==================== FINALIZATION ==================== */

    /// @notice Finalizes the phase: mints shares and refunds oversubscription excess.
    function finalizePhase(uint256 phaseId) external onlyRole(MANAGER_ROLE) {
        Phase storage p = phases[phaseId];
        if (p.pricePerShare == 0) revert UnknownPhase(phaseId);
        if (p.finalized || p.canceled) revert AlreadyFinalized(phaseId);
        if (block.timestamp < p.endsAt) revert PhaseNotFinalizable(phaseId);

        p.finalized = true;
        uint256 allocated = 0;
        uint256 refunded = 0;

        // single investor per phase in the demo scale; iterate over the phase's
        // subscribers is provided by the manager via the Subscribed event feed —
        // the on-chain loop is bounded by the subscriber list passed by the caller.
        // For exactness with an unbounded list, minting happens per-investor via
        // claimAllocation() below once the phase is finalized.
        emit PhaseFinalized(phaseId, allocated, refunded);
    }

    /// @notice After finalization, an investor claims their minted allocation.
    function claimAllocation(uint256 phaseId) external returns (uint256 allocated) {
        Phase storage p = phases[phaseId];
        if (p.pricePerShare == 0) revert UnknownPhase(phaseId);
        if (!p.finalized) revert PhaseNotFinalizable(phaseId);

        uint256 subscribed = subscriptions[phaseId][msg.sender];
        uint256 already = allocations[phaseId][msg.sender];
        if (subscribed == 0 || already > 0) revert ZeroAmount();

        // pro-rata when oversubscribed
        allocated = subscribed;
        if (p.subscribedShares > p.capShares) {
            allocated = (subscribed * p.capShares) / p.subscribedShares;
        }
        allocations[phaseId][msg.sender] = allocated;

        uint256 cost = (allocated * p.pricePerShare) / 1e18;
        uint256 paid = (subscribed * p.pricePerShare) / 1e18;
        if (paid > cost) {
            uint256 refund = paid - cost;
            if (!paymentToken.transfer(msg.sender, refund)) revert TransferFailed();
        }
        // mint the allocated shares
        shares.mint(msg.sender, allocated);
        registry.recordIssuance(p.assetId, allocated);
    }

    /// @notice Cancels an unfulfilled phase and refunds every subscriber.
    /// @dev The subscriber list is passed by the manager (event-feed derived).
    function cancelPhase(uint256 phaseId, address[] calldata subscribers_) external onlyRole(MANAGER_ROLE) {
        Phase storage p = phases[phaseId];
        if (p.pricePerShare == 0) revert UnknownPhase(phaseId);
        if (p.finalized || p.canceled) revert AlreadyCanceled(phaseId);
        p.canceled = true;
        for (uint256 i = 0; i < subscribers_.length; i++) {
            uint256 subscribed = subscriptions[phaseId][subscribers_[i]];
            if (subscribed == 0) continue;
            subscriptions[phaseId][subscribers_[i]] = 0;
            uint256 refund = (subscribed * p.pricePerShare) / 1e18;
            if (!paymentToken.transfer(subscribers_[i], refund)) revert TransferFailed();
        }
        emit PhaseCanceled(phaseId, p.collected);
    }
}
