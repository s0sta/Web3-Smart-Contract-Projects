// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";
import {AccessControl} from "./AccessControl.sol";
import {TamweelVault} from "./TamweelVault.sol";
import {TamweelMarkets} from "./TamweelMarkets.sol";

/// @title TamweelInsuranceFund
/// @notice The bad-debt backstop: funded by the rate model's reserve factor (the
///         markets route the reserve share here) and by direct donations. When a
///         market holds unrecoverable bad debt, the credit committee approves a
///         payout into the vault so depositors stay whole.
contract TamweelInsuranceFund is AccessControl {
    /// @notice The credit committee approves payouts.
    bytes32 public constant COMMITTEE_ROLE = keccak256("COMMITTEE");

    /// @notice The markets contract feeds the reserve share in.
    bytes32 public constant MARKETS_ROLE = keccak256("MARKETS");

    /// @notice One bad-debt claim.
    struct Claim {
        uint256 marketId;
        uint256 amount;
        string reason;
        mapping(address member => bool) approvals;
        uint256 approvalsCount;
        uint256 rejectionsCount;
        bool decided;
        bool approved;
    }

    Claim[] public claims;

    uint256 public totalFunded;
    uint256 public totalPaidOut;

    /// @notice The committee size (2 approvals required).
    uint256 public committeeSize;

    TamweelVault public immutable vault;
    IERC20 public immutable paymentToken;

    event Funded(address indexed from, uint256 amount);
    event ClaimFiled(uint256 indexed claimId, uint256 marketId, uint256 amount, string reason);
    event ClaimVoted(uint256 indexed claimId, address indexed member, bool approve);
    event ClaimPaid(uint256 indexed claimId, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownClaim(uint256 claimId);
    error AlreadyDecided(uint256 claimId);
    error AlreadyVoted(uint256 claimId, address member);
    error NotCommittee();
    error InsufficientFund(uint256 available, uint256 needed);
    error TransferFailed();

    constructor(TamweelVault vault_, IERC20 paymentToken_) {
        if (address(vault_) == address(0) || address(paymentToken_) == address(0)) revert ZeroAddress();
        vault = vault_;
        paymentToken = paymentToken_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(COMMITTEE_ROLE, msg.sender);
        _grantRole(MARKETS_ROLE, msg.sender);
    }

    function setCommitteeSize(uint256 n) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (n < 2 || n > 16) revert ZeroAmount();
        committeeSize = n;
    }

    /* ==================== FUNDING ==================== */

    /// @notice The markets route their reserve share here.
    function receiveReserve(uint256 amount) external onlyRole(MARKETS_ROLE) {
        if (amount == 0) revert ZeroAmount();
        if (!paymentToken.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        totalFunded += amount;
        emit Funded(msg.sender, amount);
    }

    /// @notice Anyone may donate to the backstop.
    function donate(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (!paymentToken.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        totalFunded += amount;
        emit Funded(msg.sender, amount);
    }

    /* ==================== CLAIMS ==================== */

    function fileClaim(uint256 marketId, uint256 amount, string calldata reason) external onlyRole(COMMITTEE_ROLE) returns (uint256 claimId) {
        if (amount == 0) revert ZeroAmount();
        claimId = claims.length;
        claims.push();
        Claim storage c = claims[claimId];
        c.marketId = marketId;
        c.amount = amount;
        c.reason = reason;
        emit ClaimFiled(claimId, marketId, amount, reason);
    }

    function voteClaim(uint256 claimId, bool approve) external onlyRole(COMMITTEE_ROLE) {
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
        } else if (c.rejectionsCount >= committeeSize - 1) {
            c.decided = true;
        }
    }

    function _settleClaim(uint256 claimId) internal {
        Claim storage c = claims[claimId];
        uint256 balance = paymentToken.balanceOf(address(this));
        if (balance < c.amount) revert InsufficientFund(balance, c.amount);
        totalPaidOut += c.amount;
        // inject the coverage into the vault so depositors stay whole
        if (!paymentToken.approve(address(vault), c.amount)) revert TransferFailed();
        vault.injectCoverage(c.amount);
        emit ClaimPaid(claimId, c.amount);
    }
}
