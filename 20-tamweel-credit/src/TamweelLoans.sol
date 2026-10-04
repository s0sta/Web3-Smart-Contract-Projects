// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";
import {AccessControl} from "./AccessControl.sol";
import {TamweelCompliance} from "./TamweelCompliance.sol";
import {TamweelVault} from "./TamweelVault.sol";

/// @title TamweelLoans
/// @notice The loan book: fixed-term amortized installment loans. Borrowers must
///         pass the credit score gating and a committee approval; repayments run
///         on an on-chain schedule; late fees are routed to charity (never to the
///         bank); early settlement earns a rebate on the remaining interest; and
///         chronic delinquency ends in default with financier recovery.
contract TamweelLoans is AccessControl {
    /// @notice The credit committee approves loans.
    bytes32 public constant COMMITTEE_ROLE = keccak256("COMMITTEE");

    /// @notice The financier funds disbursements.
    bytes32 public constant FINANCIER_ROLE = keccak256("FINANCIER");

    /// @notice Loan status.
    enum Status { Requested, Approved, Active, Settled, Defaulted, Rejected }

    /// @notice One loan.
    struct Loan {
        address borrower;
        uint256 principal; // disbursed amount
        uint256 interest; // fixed disclosed interest (no compounding)
        uint256 installmentAmount; // (principal + interest) / installments
        uint256 installments;
        uint256 paidInstallments;
        uint64 firstDue;
        uint64 interval;
        uint256 lateFeeCharged; // fees routed to charity
        uint256 rebateGiven; // early-settlement rebates
        string purpose;
        Status status;
    }

    Loan[] public loans;

    /// @notice Charity address for late fees (never the bank).
    address public charity;

    /// @notice Early-settlement rebate on the remaining interest (bps).
    uint256 public settlementRebateBps;

    /// @notice Late penalty per missed installment (bps of the installment).
    uint256 public latePenaltyBps;

    /// @notice Tolerated missed installments before default.
    uint256 public maxMissedInstallments;

    /// @notice Flat interest rate applied to the principal (bps).
    uint256 public loanInterestBps;

    TamweelCompliance public immutable compliance;
    TamweelVault public immutable vault;
    IERC20 public immutable paymentToken;

    event LoanRequested(uint256 indexed loanId, address indexed borrower, uint256 principal, string purpose);
    event LoanApproved(uint256 indexed loanId);
    event LoanRejected(uint256 indexed loanId);
    event LoanDisbursed(uint256 indexed loanId, uint256 amount);
    event InstallmentPaid(uint256 indexed loanId, uint256 amount, uint256 installment);
    event LateFeeCharged(uint256 indexed loanId, uint256 fee, address indexed charity);
    event LoanSettled(uint256 indexed loanId, uint256 rebate);
    event LoanDefaulted(uint256 indexed loanId);
    event Recovered(uint256 indexed loanId, address indexed to, uint256 amount);
    event CharitySet(address indexed charity);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownLoan(uint256 loanId);
    error InvalidState(uint256 loanId, Status expected, Status actual);
    error CreditDenied(address borrower);
    error NotBorrowerOrFinancier(uint256 loanId);
    error NoInstallmentsDue();
    error TransferFailed();

    constructor(
        TamweelCompliance compliance_,
        TamweelVault vault_,
        IERC20 paymentToken_,
        address charity_,
        uint256 loanInterestBps_,
        uint256 settlementRebateBps_,
        uint256 latePenaltyBps_,
        uint256 maxMissedInstallments_
    ) {
        if (address(compliance_) == address(0) || address(vault_) == address(0) || address(paymentToken_) == address(0) || charity_ == address(0)) {
            revert ZeroAddress();
        }
        compliance = compliance_;
        vault = vault_;
        paymentToken = paymentToken_;
        charity = charity_;
        loanInterestBps = loanInterestBps_;
        settlementRebateBps = settlementRebateBps_;
        latePenaltyBps = latePenaltyBps_;
        maxMissedInstallments = maxMissedInstallments_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(COMMITTEE_ROLE, msg.sender);
        _grantRole(FINANCIER_ROLE, msg.sender);
    }

    /* ==================== ORIGINATION ==================== */

    function requestLoan(uint256 principal, uint256 installments, uint64 interval, string calldata purpose) external returns (uint256 loanId) {
        if (principal == 0 || installments == 0 || interval == 0) revert ZeroAmount();
        compliance.validateBorrow(msg.sender, principal);
        loanId = loans.length;
        loans.push();
        Loan storage l = loans[loanId];
        l.borrower = msg.sender;
        l.principal = principal;
        l.interest = (principal * loanInterestBps) / 10_000;
        l.installmentAmount = (principal + l.interest) / installments;
        l.installments = installments;
        l.firstDue = uint64(block.timestamp + 30 days);
        l.interval = interval;
        l.purpose = purpose;
        l.status = Status.Requested;
        emit LoanRequested(loanId, msg.sender, principal, purpose);
    }

    function approveLoan(uint256 loanId) external onlyRole(COMMITTEE_ROLE) {
        Loan storage l = loans[loanId];
        if (l.principal == 0) revert UnknownLoan(loanId);
        if (l.status != Status.Requested) revert InvalidState(loanId, Status.Requested, l.status);
        l.status = Status.Approved;
        emit LoanApproved(loanId);
    }

    function rejectLoan(uint256 loanId) external onlyRole(COMMITTEE_ROLE) {
        Loan storage l = loans[loanId];
        if (l.status != Status.Requested) revert InvalidState(loanId, Status.Requested, l.status);
        l.status = Status.Rejected;
        emit LoanRejected(loanId);
    }

    /// @notice The financier disburses the principal from the vault's liquidity.
    function disburse(uint256 loanId) external onlyRole(FINANCIER_ROLE) {
        Loan storage l = loans[loanId];
        if (l.status != Status.Approved) revert InvalidState(loanId, Status.Approved, l.status);
        vault.lendToMarkets(l.principal);
        if (!paymentToken.transfer(l.borrower, l.principal)) revert TransferFailed();
        l.status = Status.Active;
        emit LoanDisbursed(loanId, l.principal);
    }

    /* ==================== REPAYMENT ==================== */

    function missedInstallments(uint256 loanId) public view returns (uint256) {
        Loan storage l = loans[loanId];
        if (l.paidInstallments >= l.installments) return 0;
        uint256 dueSoFar = block.timestamp > l.firstDue ? (block.timestamp - l.firstDue) / l.interval + 1 : 0;
        if (dueSoFar <= l.paidInstallments) return 0;
        return dueSoFar - l.paidInstallments;
    }

    function payInstallment(uint256 loanId) external {
        Loan storage l = loans[loanId];
        if (l.principal == 0) revert UnknownLoan(loanId);
        if (msg.sender != l.borrower && !hasRole(FINANCIER_ROLE, msg.sender)) revert NotBorrowerOrFinancier(loanId);
        if (l.status != Status.Active) revert InvalidState(loanId, Status.Active, l.status);

        uint256 missed = missedInstallments(loanId);
        if (missed > 0) {
            uint256 fee = (l.installmentAmount * latePenaltyBps * missed) / 10_000;
            l.lateFeeCharged += fee;
            if (!paymentToken.transferFrom(msg.sender, charity, fee)) revert TransferFailed();
            emit LateFeeCharged(loanId, fee, charity);
        }

        l.paidInstallments += 1 + missed;
        uint256 pay = l.installmentAmount * (1 + missed);
        if (!paymentToken.transferFrom(msg.sender, address(vault), pay)) revert TransferFailed();
        vault.recoverFromMarkets(pay);
        emit InstallmentPaid(loanId, pay, l.paidInstallments);

        if (l.paidInstallments >= l.installments) {
            l.status = Status.Settled;
            emit LoanSettled(loanId, 0);
        }
    }

    /// @notice Early settlement: the remaining installments with a rebate on the
    ///         remaining interest (the bank forgoes part of its profit).
    function settleEarly(uint256 loanId) external {
        Loan storage l = loans[loanId];
        if (l.principal == 0) revert UnknownLoan(loanId);
        if (msg.sender != l.borrower) revert NotBorrowerOrFinancier(loanId);
        if (l.status != Status.Active) revert InvalidState(loanId, Status.Active, l.status);

        uint256 remaining = l.installments - l.paidInstallments;
        if (remaining == 0) revert NoInstallmentsDue();
        uint256 remainingInterest = (l.interest * remaining) / l.installments;
        uint256 rebate = (remainingInterest * settlementRebateBps) / 10_000;
        uint256 due = remaining * l.installmentAmount - rebate;

        if (!paymentToken.transferFrom(msg.sender, address(vault), due)) revert TransferFailed();
        vault.recoverFromMarkets(due);
        l.rebateGiven += rebate;
        l.paidInstallments = l.installments;
        l.status = Status.Settled;
        emit LoanSettled(loanId, rebate);
    }

    /* ==================== DEFAULT & RECOVERY ==================== */

    function markDefault(uint256 loanId) external {
        Loan storage l = loans[loanId];
        if (l.status != Status.Active) revert InvalidState(loanId, Status.Active, l.status);
        if (missedInstallments(loanId) <= maxMissedInstallments) revert NoInstallmentsDue();
        l.status = Status.Defaulted;
        emit LoanDefaulted(loanId);
    }

    /// @notice The financier recovers collected funds from a settled/defaulted loan.
    function recover(uint256 loanId, address to, uint256 amount) external onlyRole(FINANCIER_ROLE) {
        Loan storage l = loans[loanId];
        if (l.status != Status.Settled && l.status != Status.Defaulted) {
            revert InvalidState(loanId, Status.Settled, l.status);
        }
        if (amount == 0) revert ZeroAmount();
        if (!paymentToken.transfer(to, amount)) revert TransferFailed();
        emit Recovered(loanId, to, amount);
    }

    /* ==================== ADMIN ==================== */

    function setCharity(address charity_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (charity_ == address(0)) revert ZeroAddress();
        charity = charity_;
        emit CharitySet(charity_);
    }

    function setLoanInterestBps(uint256 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > 10_000) revert ZeroAmount();
        loanInterestBps = bps;
    }

    function setSettlementRebateBps(uint256 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > 10_000) revert ZeroAmount();
        settlementRebateBps = bps;
    }
}
