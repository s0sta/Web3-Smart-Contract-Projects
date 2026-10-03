// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";
import {AccessControl} from "./AccessControl.sol";
import {MawaridRentalDistributor} from "./MawaridRentalDistributor.sol";

/// @title MawaridInsuranceFund
/// @notice A per-asset risk pool that covers rental shortfalls: the manager pays
///         premiums from the asset's maintenance fund, and when a tenant defaults,
///         the manager files a claim that needs 2-of-3 committee approvals before
///         the shortfall is covered into the asset's distribution pool.
contract MawaridInsuranceFund is AccessControl {
    /// @notice The platform manager files claims and pays premiums.
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER");

    /// @notice The claims committee (independent assessors).
    bytes32 public constant ASSESSOR_ROLE = keccak256("ASSESSOR");

    /// @notice One claim.
    struct Claim {
        uint256 assetId;
        uint256 amount;
        string reason;
        mapping(address assessor => bool) approvals;
        uint256 approvalsCount;
        uint256 rejectionsCount;
        bool decided;
        bool approved;
    }

    Claim[] public claims;

    /// @notice Premium pool per asset.
    mapping(uint256 assetId => uint256) public pool;

    /// @notice The committee size (2 approvals required).
    uint256 public assessorCount;

    MawaridRentalDistributor public immutable distributor;
    IERC20 public immutable paymentToken;

    event PremiumPaid(uint256 indexed assetId, uint256 amount);
    event ClaimFiled(uint256 indexed claimId, uint256 indexed assetId, uint256 amount, string reason);
    event ClaimVoted(uint256 indexed claimId, address indexed assessor, bool approve);
    event ClaimPaid(uint256 indexed claimId, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownClaim(uint256 claimId);
    error AlreadyDecided(uint256 claimId);
    error AlreadyVoted(uint256 claimId, address assessor);
    error NotAssessor();
    error InsufficientPool(uint256 available, uint256 needed);
    error TransferFailed();

    constructor(MawaridRentalDistributor distributor_, IERC20 paymentToken_) {
        if (address(distributor_) == address(0) || address(paymentToken_) == address(0)) revert ZeroAddress();
        distributor = distributor_;
        paymentToken = paymentToken_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);
        _grantRole(ASSESSOR_ROLE, msg.sender);
    }

    function setAssessorCount(uint256 n) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (n < 2 || n > 16) revert ZeroAmount();
        assessorCount = n;
    }

    /* ==================== PREMIUMS & CLAIMS ==================== */

    /// @notice The manager pays a premium from the asset's maintenance fund.
    function payPremium(uint256 assetId, uint256 amount) external onlyRole(MANAGER_ROLE) {
        if (amount == 0) revert ZeroAmount();
        // premiums are drawn from the maintenance fund via the distributor
        distributor.spendMaintenance(assetId, address(this), amount);
        pool[assetId] += amount;
        emit PremiumPaid(assetId, amount);
    }

    function fileClaim(uint256 assetId, uint256 amount, string calldata reason) external onlyRole(MANAGER_ROLE) returns (uint256 claimId) {
        if (amount == 0) revert ZeroAmount();
        claimId = claims.length;
        claims.push();
        Claim storage c = claims[claimId];
        c.assetId = assetId;
        c.amount = amount;
        c.reason = reason;
        emit ClaimFiled(claimId, assetId, amount, reason);
    }

    function voteClaim(uint256 claimId, bool approve) external onlyRole(ASSESSOR_ROLE) {
        Claim storage c = claims[claimId];
        if (c.amount == 0) revert UnknownClaim(claimId);
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
            c.decided = true;
        }
    }

    function _settleClaim(uint256 claimId) internal {
        Claim storage c = claims[claimId];
        if (pool[c.assetId] < c.amount) revert InsufficientPool(pool[c.assetId], c.amount);
        pool[c.assetId] -= c.amount;
        // the payout re-enters the asset's income pool so holders receive it
        if (!paymentToken.approve(address(distributor), c.amount)) revert TransferFailed();
        // note: the distributor pulls from this contract on recordIncome
        // — the manager records the covered income in the next step
        emit ClaimPaid(claimId, c.amount);
    }
}
