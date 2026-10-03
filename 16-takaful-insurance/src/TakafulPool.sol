// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";
import {AccessControl} from "./AccessControl.sol";
import {Checkpoints} from "./lib/Checkpoints.sol";

/// @title TakafulPool
/// @notice A Sharia-compliant mutual insurance pool (takaful, wakalah model):
///
///   · **Tabarru** — participants contribute into a shared risk pool per coverage
///     type (motor / health / property); the operator withholds a wakalah fee.
///   · **Policies** — each contribution mints a policy with a coverage window and
///     a per-policy claim limit.
///   · **Claims committee** — claims are filed by the policy holder and must win
///     2-of-N independent assessor approvals before any payout.
///   · **Surplus** — at each accounting period boundary, the underwriting surplus
///     (contributions − claims − fees + investment income − reserves) is distributed
///     pro-rata to participants who did NOT claim during the period (no-claim benefit),
///     based on contribution snapshots.
///   · **Qard hasan** — if a pool is deficient, an interest-free bridge facility
///     (donations) covers claims; it is repaid from future contributions.
contract TakafulPool is AccessControl {
    using Checkpoints for Checkpoints.Checkpoint[];

    /// @notice The operator (wakeel): registers pools, collects the wakalah fee.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR");

    /// @notice The independent claims committee.
    bytes32 public constant ASSESSOR_ROLE = keccak256("ASSESSOR");

    /// @notice The Shariah supervisory board.
    bytes32 public constant SHARIAH_ROLE = keccak256("SHARIAH");

    /// @notice One risk pool (coverage type).
    struct Pool {
        string name; // "Motor", "Health", "Property"
        uint256 contributionAmount; // tabarru per policy
        uint256 wakalahFeeBps; // operator fee on each contribution
        uint256 claimLimit; // max payout per policy
        uint64 coveragePeriod; // policy duration
        uint64 periodLength; // accounting period for the surplus
        uint256 totalContributions; // all-time net tabarru
        uint256 totalClaimsPaid; // all-time payouts
        uint256 qardHasanDrawn; // interest-free bridge currently outstanding
        bool active;
    }

    Pool[] public pools;

    /// @notice One policy.
    struct Policy {
        uint256 poolId;
        address holder;
        uint64 coverageStart;
        uint64 coverageEnd;
        uint256 contribution; // net of the wakalah fee
        uint256 claimed; // total paid for this policy
        bool active;
    }

    Policy[] public policies;

    /// @notice One claim.
    struct Claim {
        uint256 policyId;
        uint256 amount;
        string reason;
        uint64 filedAt;
        mapping(address assessor => bool) approvals;
        uint256 approvalsCount;
        uint256 rejectionsCount;
        bool decided;
        bool approved;
    }

    Claim[] public claims;

    /// @notice The size of the claims committee (2 approvals required).
    uint256 public assessorCount;

    /// @notice Contribution snapshot per participant per pool (surplus basis).
    mapping(uint256 poolId => mapping(address participant => Checkpoints.Checkpoint[])) private _contribHistory;

    /// @notice The last accounting period a participant received a surplus for.
    mapping(uint256 poolId => mapping(address participant => uint256)) public lastSurplusPeriod;

    /// @notice Whether the participant claimed during the current period.
    mapping(uint256 poolId => mapping(address participant => bool)) public claimedThisPeriod;

    /// @notice Interest-free bridge facility balance.
    uint256 public qardHasanFacility;

    /// @notice Total wakalah fees collected (operator income).
    uint256 public totalWakalahFees;

    /// @notice Permissible investment income recorded into the pools.
    uint256 public investmentIncome;

    /// @notice The contribution/payout token (AED-pegged stable).
    IERC20 public immutable paymentToken;

    bool public paused;

    event PoolRegistered(uint256 indexed poolId, string name, uint256 contributionAmount, uint256 claimLimit);
    event PolicyIssued(uint256 indexed policyId, uint256 indexed poolId, address indexed holder, uint256 contribution);
    event ClaimFiled(uint256 indexed claimId, uint256 indexed policyId, uint256 amount, string reason);
    event ClaimVoted(uint256 indexed claimId, address indexed assessor, bool approve);
    event ClaimPaid(uint256 indexed claimId, uint256 indexed policyId, uint256 amount);
    event ClaimRejected(uint256 indexed claimId);
    event SurplusDistributed(uint256 indexed poolId, uint256 period, uint256 surplus, uint256 participants);
    event QardHasanFunded(address indexed donor, uint256 amount);
    event QardHasanDrawn(uint256 amount);
    event QardHasanRepaid(uint256 amount);
    event WakalahFeeSet(uint256 indexed poolId, uint256 bps);
    event Paused(bool paused);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownPool(uint256 poolId);
    error UnknownPolicy(uint256 policyId);
    error PoolInactive(uint256 poolId);
    error ProtocolPaused();
    error PolicyExpired(uint256 policyId);
    error PolicyClaimLimit(uint256 claimed, uint256 limit);
    error NotPolicyHolder(uint256 policyId);
    error AlreadyDecided(uint256 claimId);
    error NotAssessor();
    error AlreadyVoted(uint256 claimId, address assessor);
    error ClaimNotApproved(uint256 claimId);
    error InsufficientQardHasan(uint256 available, uint256 needed);
    error NoSurplus();
    error TransferFailed();

    constructor(IERC20 paymentToken_) {
        if (address(paymentToken_) == address(0)) revert ZeroAddress();
        paymentToken = paymentToken_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(ASSESSOR_ROLE, msg.sender);
        _grantRole(SHARIAH_ROLE, msg.sender);
        _grantRole(GUARDIAN_ROLE, msg.sender);
    }

    modifier whenNotPaused() {
        if (paused) revert ProtocolPaused();
        _;
    }

    /* ==================== POOLS ==================== */

    function registerPool(
        string calldata name,
        uint256 contributionAmount,
        uint256 wakalahFeeBps,
        uint256 claimLimit,
        uint64 coveragePeriod,
        uint64 periodLength
    ) external onlyRole(OPERATOR_ROLE) returns (uint256 poolId) {
        if (contributionAmount == 0 || claimLimit == 0 || coveragePeriod == 0 || periodLength == 0) revert ZeroAmount();
        if (wakalahFeeBps > 10_000) revert ZeroAmount();
        poolId = pools.length;
        pools.push(
            Pool({
                name: name,
                contributionAmount: contributionAmount,
                wakalahFeeBps: wakalahFeeBps,
                claimLimit: claimLimit,
                coveragePeriod: coveragePeriod,
                periodLength: periodLength,
                totalContributions: 0,
                totalClaimsPaid: 0,
                qardHasanDrawn: 0,
                active: true
            })
        );
        emit PoolRegistered(poolId, name, contributionAmount, claimLimit);
    }

    function setWakalahFee(uint256 poolId, uint256 bps) external onlyRole(OPERATOR_ROLE) {
        if (pools[poolId].contributionAmount == 0) revert UnknownPool(poolId);
        if (bps > 10_000) revert ZeroAmount();
        pools[poolId].wakalahFeeBps = bps;
        emit WakalahFeeSet(poolId, bps);
    }

    function setAssessorCount(uint256 n) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (n < 2 || n > 16) revert ZeroAmount();
        assessorCount = n;
    }

    /* ==================== POLICIES (TABARRU) ==================== */

    /// @notice A participant contributes tabarru and receives a policy.
    function joinPool(uint256 poolId) external whenNotPaused returns (uint256 policyId) {
        Pool storage p = pools[poolId];
        if (p.contributionAmount == 0) revert UnknownPool(poolId);
        if (!p.active) revert PoolInactive(poolId);

        uint256 fee = (p.contributionAmount * p.wakalahFeeBps) / 10_000;
        uint256 net = p.contributionAmount - fee;
        if (!paymentToken.transferFrom(msg.sender, address(this), p.contributionAmount)) revert TransferFailed();

        p.totalContributions += net;
        totalWakalahFees += fee;

        policyId = policies.length;
        policies.push(
            Policy({
                poolId: poolId,
                holder: msg.sender,
                coverageStart: uint64(block.timestamp),
                coverageEnd: uint64(block.timestamp + p.coveragePeriod),
                contribution: net,
                claimed: 0,
                active: true
            })
        );
        _contribHistory[poolId][msg.sender].write(_contribHistory[poolId][msg.sender].latest(), _contribHistory[poolId][msg.sender].latest() + net);
        emit PolicyIssued(policyId, poolId, msg.sender, p.contributionAmount);
    }

    /* ==================== CLAIMS ==================== */

    function fileClaim(uint256 policyId, uint256 amount, string calldata reason) external whenNotPaused returns (uint256 claimId) {
        Policy storage pol = policies[policyId];
        if (pol.contribution == 0) revert UnknownPolicy(policyId);
        if (msg.sender != pol.holder) revert NotPolicyHolder(policyId);
        if (block.timestamp > pol.coverageEnd) revert PolicyExpired(policyId);
        if (pol.claimed + amount > pools[pol.poolId].claimLimit) {
            revert PolicyClaimLimit(pol.claimed, pools[pol.poolId].claimLimit);
        }
        if (amount == 0) revert ZeroAmount();

        claimId = claims.length;
        Claim storage c = claims.push();
        c.policyId = policyId;
        c.amount = amount;
        c.reason = reason;
        c.filedAt = uint64(block.timestamp);
        emit ClaimFiled(claimId, policyId, amount, reason);
    }

    /// @notice Assessors independently vote; 2 approvals settle the claim.
    function voteClaim(uint256 claimId, bool approve) external onlyRole(ASSESSOR_ROLE) {
        Claim storage c = claims[claimId];
        if (c.amount == 0) revert ZeroAmount();
        if (c.decided) revert AlreadyDecided(claimId);
        if (c.approvals[msg.sender]) revert AlreadyVoted(claimId, msg.sender);

        c.approvals[msg.sender] = true;
        if (approve) c.approvalsCount += 1;
        else c.rejectionsCount += 1;
        emit ClaimVoted(claimId, msg.sender, approve);

        if (c.approvalsCount >= 2) {
            c.decided = true;
            c.approved = true;
            _settleClaim(claimId);
        } else if (c.rejectionsCount >= assessorCount - 1) {
            // two approvals are no longer reachable
            c.decided = true;
            emit ClaimRejected(claimId);
        }
    }

    function _settleClaim(uint256 claimId) internal {
        Claim storage c = claims[claimId];
        Policy storage pol = policies[c.policyId];
        Pool storage p = pools[pol.poolId];

        uint256 amount = c.amount;
        uint256 available = paymentToken.balanceOf(address(this)) - qardHasanFacility;

        if (available < amount) {
            uint256 needed = amount - available;
            if (qardHasanFacility < needed) revert InsufficientQardHasan(qardHasanFacility, needed);
            qardHasanFacility -= needed;
            p.qardHasanDrawn += needed;
            emit QardHasanDrawn(needed);
        }

        pol.claimed += amount;
        p.totalClaimsPaid += amount;
        claimedThisPeriod[pol.poolId][pol.holder] = true;

        if (!paymentToken.transfer(pol.holder, amount)) revert TransferFailed();
        emit ClaimPaid(claimId, c.policyId, amount);
    }

    function availableForPayout() public view returns (uint256) {
        return paymentToken.balanceOf(address(this)) - qardHasanFacility;
    }

    /* ==================== SURPLUS (NO-CLAIM BENEFIT) ==================== */

    /// @notice Distributes the period's underwriting surplus pro-rata to the
    ///         non-claiming participants listed by the operator. Each address is
    ///         verified against the contribution history before being paid.
    function distributeSurplus(uint256 poolId, address[] calldata participants) external onlyRole(OPERATOR_ROLE) returns (uint256 surplus) {
        Pool storage p = pools[poolId];
        if (p.contributionAmount == 0) revert UnknownPool(poolId);

        uint256 period = block.timestamp / p.periodLength;

        // conservative surplus: everything above the qard bridge + a reserve floor
        uint256 reserveFloor = p.contributionAmount * 10;
        uint256 available = availableForPayout();
        if (available <= reserveFloor + p.qardHasanDrawn) revert NoSurplus();
        surplus = available - reserveFloor - p.qardHasanDrawn;

        // total eligible contributions (non-claimers who have not been paid this period)
        uint256 eligibleTotal = 0;
        uint256 eligibleCount = 0;
        for (uint256 i = 0; i < participants.length; i++) {
            address participant = participants[i];
            if (claimedThisPeriod[poolId][participant]) continue;
            if (lastSurplusPeriod[poolId][participant] > period) continue;
            uint256 contrib = _contribHistory[poolId][participant].latest();
            if (contrib == 0) continue;
            eligibleTotal += contrib;
            eligibleCount += 1;
        }
        if (eligibleTotal == 0) revert NoSurplus();

        for (uint256 i = 0; i < participants.length; i++) {
            address participant = participants[i];
            if (claimedThisPeriod[poolId][participant]) continue;
            if (lastSurplusPeriod[poolId][participant] > period) continue;
            uint256 contrib = _contribHistory[poolId][participant].latest();
            if (contrib == 0) continue;
            uint256 share = (surplus * contrib) / eligibleTotal;
            if (share == 0) continue;
            lastSurplusPeriod[poolId][participant] = period + 1;
            if (!paymentToken.transfer(participant, share)) revert TransferFailed();
        }
        emit SurplusDistributed(poolId, period, surplus, eligibleCount);
    }

    /* ==================== QARD HASAN FACILITY ==================== */

    function fundQardHasan(uint256 amount) external whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (!paymentToken.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        qardHasanFacility += amount;
        emit QardHasanFunded(msg.sender, amount);
    }

    /// @notice The operator repays the outstanding bridge from pool inflows.
    function repayQardHasan(uint256 amount) external onlyRole(OPERATOR_ROLE) {
        uint256 outstanding = 0;
        for (uint256 i = 0; i < pools.length; i++) outstanding += pools[i].qardHasanDrawn;
        if (amount == 0 || amount > outstanding) revert ZeroAmount();

        uint256 remaining = amount;
        for (uint256 i = 0; i < pools.length && remaining > 0; i++) {
            uint256 d = pools[i].qardHasanDrawn;
            uint256 repay = d < remaining ? d : remaining;
            pools[i].qardHasanDrawn -= repay;
            remaining -= repay;
        }
        qardHasanFacility += amount;
        emit QardHasanRepaid(amount);
    }

    /* ==================== INCOME & GUARDIAN ==================== */

    function recordInvestmentIncome(uint256 amount) external onlyRole(OPERATOR_ROLE) {
        if (amount == 0) revert ZeroAmount();
        if (!paymentToken.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        investmentIncome += amount;
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        paused = true;
        emit Paused(true);
    }

    function unpause() external onlyRole(GUARDIAN_ROLE) {
        paused = false;
        emit Paused(false);
    }

    /* ==================== SNAPSHOTS ==================== */

    function getPastContribution(uint256 poolId, address participant, uint256 blockNumber) external view returns (uint256) {
        return _contribHistory[poolId][participant].lookup(blockNumber);
    }
}
