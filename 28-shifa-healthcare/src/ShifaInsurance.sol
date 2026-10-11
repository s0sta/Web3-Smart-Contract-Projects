// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {ShifaRegistry} from "./ShifaRegistry.sol";
import {ShifaTreasury} from "./ShifaTreasury.sol";

/// @title ShifaInsurance
/// @notice Health cover. A member subscribes to an insurer's plan with a yearly
///         limit and a copay percentage. Providers ask for pre-authorisation
///         before a treatment, then file the claim; a two-of-three medical review
///         panel approves it, the insurer pool pays its share to the provider and
///         the patient's share is recorded for the payment desk to collect.
contract ShifaInsurance is AccessControl {
    /// @notice Medical reviewers decide claims.
    bytes32 public constant REVIEWER_ROLE = keccak256("REVIEWER");

    /// @notice One health plan.
    struct Plan {
        address member;
        address insurer;
        uint256 coverageLimit; // total the insurer will pay this year
        uint256 usedAmount;
        uint16 copayBps; // the patient's share of every approved claim
        uint64 startAt;
        uint64 endAt;
        bool active;
    }

    /// @notice Pre-authorisation given by the insurer before treatment.
    struct PreAuth {
        uint256 planId;
        address provider;
        bytes32 serviceHash;
        uint256 maxAmount;
        uint64 expiresAt;
        bool used;
    }

    /// @notice One claim.
    struct Claim {
        uint256 preAuthId;
        address provider;
        uint256 amount;
        uint256 insurerShare;
        uint256 patientShare;
        mapping(address reviewer => bool) voted;
        uint256 approvals;
        uint256 rejections;
        bool decided;
        bool approved;
        bool paid;
    }

    Plan[] public plans;
    PreAuth[] public preAuths;
    Claim[] public claims;

    mapping(address member => uint256) public activePlanOf;
    uint256 public totalPremiums;
    uint256 public totalPaidOut;

    /// @notice Yearly premium as bps of the coverage limit.
    uint256 public premiumRateBps;

    ShifaRegistry public immutable registry;
    ShifaTreasury public immutable treasury;
    IERC20 public immutable paymentToken;

    event PlanCreated(uint256 indexed planId, address indexed member, address indexed insurer, uint256 coverageLimit, uint16 copayBps);
    event PremiumPaid(uint256 indexed planId, uint256 amount);
    event PreAuthorized(uint256 indexed preAuthId, uint256 indexed planId, address indexed provider, uint256 maxAmount, uint64 expiresAt);
    event ClaimFiled(uint256 indexed claimId, uint256 indexed preAuthId, address indexed provider, uint256 amount);
    event ClaimVoted(uint256 indexed claimId, address indexed reviewer, bool approve);
    event ClaimPaid(uint256 indexed claimId, uint256 insurerShare, uint256 patientShare);
    event PremiumRateSet(uint256 bps);

    error ZeroAddress();
    error ZeroAmount();
    error NotInsurer();
    error NotProvider();
    error NotReviewer();
    error UnknownPlan(uint256 planId);
    error UnknownPreAuth(uint256 preAuthId);
    error UnknownClaim(uint256 claimId);
    error PlanInactive(uint256 planId);
    error AlreadyDecided(uint256 claimId);
    error AlreadyVoted(uint256 claimId, address reviewer);
    error PreAuthExpired(uint256 preAuthId);
    error PreAuthUsed(uint256 preAuthId);
    error InsufficientPool(uint256 available, uint256 needed);
    error TransferFailed();

    constructor(ShifaRegistry registry_, ShifaTreasury treasury_, IERC20 paymentToken_, uint256 premiumRateBps_) {
        if (address(registry_) == address(0) || address(treasury_) == address(0) || address(paymentToken_) == address(0)) {
            revert ZeroAddress();
        }
        registry = registry_;
        treasury = treasury_;
        paymentToken = paymentToken_;
        premiumRateBps = premiumRateBps_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(REVIEWER_ROLE, msg.sender);
    }

    /* ==================== PLANS ==================== */

    function subscribe(address insurer, uint256 coverageLimit, uint16 copayBps, uint64 durationDays) external returns (uint256 planId, uint256 premium) {
        if (!registry.isActive(insurer) || registry.roleOf(insurer) != ShifaRegistry.Role.Insurer) revert NotInsurer();
        if (!registry.isActive(msg.sender)) revert ZeroAmount();
        if (coverageLimit == 0 || durationDays == 0) revert ZeroAmount();
        if (copayBps > 5_000) revert ZeroAmount();
        if (durationDays > 365) revert ZeroAmount();

        premium = (coverageLimit * premiumRateBps / 10_000) * durationDays / 365;
        if (premium == 0) revert ZeroAmount();

        planId = plans.length;
        plans.push();
        Plan storage p = plans[planId];
        p.member = msg.sender;
        p.insurer = insurer;
        p.coverageLimit = coverageLimit;
        p.copayBps = copayBps;
        p.startAt = uint64(block.timestamp);
        p.endAt = uint64(block.timestamp + uint256(durationDays) * 1 days);
        p.active = true;
        activePlanOf[msg.sender] = planId + 1; // +1 so 0 means "no plan"

        if (!paymentToken.transferFrom(msg.sender, address(this), premium)) revert TransferFailed();
        totalPremiums += premium;
        emit PlanCreated(planId, msg.sender, insurer, coverageLimit, copayBps);
        emit PremiumPaid(planId, premium);
    }

    function isPlanActive(uint256 planId) public view returns (bool) {
        Plan storage p = plans[planId];
        return p.active && p.member != address(0) && block.timestamp <= p.endAt;
    }

    function planCoverLeft(uint256 planId) public view returns (uint256) {
        Plan storage p = plans[planId];
        if (p.coverageLimit <= p.usedAmount) return 0;
        return p.coverageLimit - p.usedAmount;
    }

    /* ==================== PRE-AUTHORISATION ==================== */

    /// @notice The insurer approves a treatment ceiling for a member and provider.
    function preAuthorize(uint256 planId, address provider, bytes32 serviceHash, uint256 maxAmount, uint64 validDays) external returns (uint256 preAuthId) {
        Plan storage p = plans[planId];
        if (p.member == address(0)) revert UnknownPlan(planId);
        if (msg.sender != p.insurer) revert NotInsurer();
        if (!isPlanActive(planId)) revert PlanInactive(planId);
        if (maxAmount == 0 || validDays == 0 || validDays > 90) revert ZeroAmount();

        preAuthId = preAuths.length;
        preAuths.push();
        PreAuth storage a = preAuths[preAuthId];
        a.planId = planId;
        a.provider = provider;
        a.serviceHash = serviceHash;
        a.maxAmount = maxAmount;
        a.expiresAt = uint64(block.timestamp + uint256(validDays) * 1 days);
        emit PreAuthorized(preAuthId, planId, provider, maxAmount, a.expiresAt);
    }

    /* ==================== CLAIMS ==================== */

    /// @notice The provider files the claim after the treatment.
    function fileClaim(uint256 preAuthId, uint256 amount) external returns (uint256 claimId) {
        PreAuth storage a = preAuths[preAuthId];
        if (a.provider == address(0)) revert UnknownPreAuth(preAuthId);
        if (msg.sender != a.provider) revert NotProvider();
        if (a.used) revert PreAuthUsed(preAuthId);
        if (block.timestamp > a.expiresAt) revert PreAuthExpired(preAuthId);
        if (amount == 0 || amount > a.maxAmount) revert ZeroAmount();

        claimId = claims.length;
        claims.push();
        Claim storage c = claims[claimId];
        c.preAuthId = preAuthId;
        c.provider = msg.sender;
        c.amount = amount;
        emit ClaimFiled(claimId, preAuthId, msg.sender, amount);
    }

    function voteClaim(uint256 claimId, bool approve) external onlyRole(REVIEWER_ROLE) {
        Claim storage c = claims[claimId];
        if (c.provider == address(0)) revert UnknownClaim(claimId);
        if (c.decided) revert AlreadyDecided(claimId);
        if (c.voted[msg.sender]) revert AlreadyVoted(claimId, msg.sender);

        c.voted[msg.sender] = true;
        if (approve) c.approvals += 1;
        else c.rejections += 1;
        emit ClaimVoted(claimId, msg.sender, approve);

        if (c.approvals >= 2) {
            c.decided = true;
            c.approved = true;
            _settle(claimId);
        } else if (c.rejections >= 2) {
            c.decided = true;
        }
    }

    function _settle(uint256 claimId) internal {
        Claim storage c = claims[claimId];
        PreAuth storage a = preAuths[c.preAuthId];
        Plan storage p = plans[a.planId];

        uint256 payable_ = c.amount;
        uint256 left = planCoverLeft(a.planId);
        if (payable_ > left) payable_ = left;
        c.insurerShare = (payable_ * (10_000 - p.copayBps)) / 10_000;
        c.patientShare = payable_ - c.insurerShare;
        p.usedAmount += payable_;
        a.used = true;

        uint256 balance = paymentToken.balanceOf(address(this));
        if (balance < c.insurerShare) revert InsufficientPool(balance, c.insurerShare);
        if (c.insurerShare > 0) {
            if (!paymentToken.transfer(c.provider, c.insurerShare)) revert TransferFailed();
            totalPaidOut += c.insurerShare;
        }
        c.paid = true;
        emit ClaimPaid(claimId, c.insurerShare, c.patientShare);
    }

    /* ==================== QUERIES ==================== */

    function planOf(address member) external view returns (uint256) {
        uint256 stored = activePlanOf[member];
        return stored == 0 ? 0 : stored - 1;
    }

    function claimsCount() external view returns (uint256) {
        return claims.length;
    }

    function poolBalance() external view returns (uint256) {
        return paymentToken.balanceOf(address(this));
    }

    /* ==================== ADMIN ==================== */

    function setPremiumRate(uint256 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > 5_000) revert ZeroAmount();
        premiumRateBps = bps;
        emit PremiumRateSet(bps);
    }
}
