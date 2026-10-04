// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";
import {AccessControl} from "./AccessControl.sol";

/// @title SahmInsuranceFund
/// @notice The liquidation backstop: fees and direct donations fund a pool that
///         covers socialized losses from liquidations and bad debt, paid out
///         with 2-of-3 committee approval.
contract SahmInsuranceFund is AccessControl {
    /// @notice The risk committee approves payouts.
    bytes32 public constant COMMITTEE_ROLE = keccak256("COMMITTEE");

    /// @notice The venues route a share of their fees here.
    bytes32 public constant VENUE_ROLE = keccak256("VENUE");

    /// @notice One claim.
    struct Claim {
        address claimant;
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
    uint256 public committeeSize;

    IERC20 public immutable quoteToken;

    event Funded(address indexed from, uint256 amount);
    event ClaimFiled(uint256 indexed claimId, uint256 amount, string reason);
    event ClaimVoted(uint256 indexed claimId, address indexed member, bool approve);
    event ClaimPaid(uint256 indexed claimId, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownClaim(uint256 claimId);
    error AlreadyDecided(uint256 claimId);
    error AlreadyVoted(uint256 claimId, address member);
    error InsufficientFund(uint256 available, uint256 needed);
    error TransferFailed();

    constructor(IERC20 quoteToken_) {
        if (address(quoteToken_) == address(0)) revert ZeroAddress();
        quoteToken = quoteToken_;
        committeeSize = 3;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(COMMITTEE_ROLE, msg.sender);
        _grantRole(VENUE_ROLE, msg.sender);
    }

    function setCommitteeSize(uint256 n) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (n < 2 || n > 16) revert ZeroAmount();
        committeeSize = n;
    }

    /* ==================== FUNDING ==================== */

    function receiveContribution(uint256 amount) external onlyRole(VENUE_ROLE) {
        if (amount == 0) revert ZeroAmount();
        if (!quoteToken.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        totalFunded += amount;
        emit Funded(msg.sender, amount);
    }

    function donate(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (!quoteToken.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        totalFunded += amount;
        emit Funded(msg.sender, amount);
    }

    /* ==================== CLAIMS ==================== */

    function fileClaim(uint256 amount, string calldata reason) external onlyRole(COMMITTEE_ROLE) returns (uint256 claimId) {
        if (amount == 0) revert ZeroAmount();
        claimId = claims.length;
        claims.push();
        Claim storage c = claims[claimId];
        c.claimant = msg.sender;
        c.amount = amount;
        c.reason = reason;
        emit ClaimFiled(claimId, amount, reason);
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
        uint256 balance = quoteToken.balanceOf(address(this));
        if (balance < c.amount) revert InsufficientFund(balance, c.amount);
        totalPaidOut += c.amount;
        if (!quoteToken.transfer(c.claimant, c.amount)) revert TransferFailed();
        emit ClaimPaid(claimId, c.amount);
    }
}
