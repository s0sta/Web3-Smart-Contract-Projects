// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";
import {AccessControl} from "./AccessControl.sol";
import {Checkpoints} from "./lib/Checkpoints.sol";
import {AsnafRegistry} from "./AsnafRegistry.sol";

/// @title ZakatEngine
/// @notice The zakat obligation on-chain: payers declare their zakatable wealth,
///         the engine computes the 2.5% due once the wealth has been above the
///         nisab for a full lunar year (hawl), and the ring-fenced zakat fund is
///         distributed ONLY to the eight asnaf (Quran 9:60) via the committee.
contract ZakatEngine is AccessControl {
    using Checkpoints for Checkpoints.Checkpoint[];

    /// @notice The zakat committee: sets the nisab, executes disbursements.
    bytes32 public constant COMMITTEE_ROLE = keccak256("COMMITTEE");

    /// @notice The asnaf registry.
    AsnafRegistry public immutable registry;

    /// @notice The payment token (AED-pegged stable).
    IERC20 public immutable paymentToken;

    /// @notice The nisab (85g gold equivalent, in the payment token).
    uint256 public nisab;

    /// @notice The zakat rate: 2.5% = 250 bps.
    uint256 public constant ZAKAT_RATE_BPS = 250;

    /// @notice One payer's declaration.
    struct Payer {
        uint256 declaredWealth; // total zakatable wealth
        uint64 hawlStart; // when the wealth first crossed the nisab
        uint256 zakatPaid; // lifetime zakat paid
    }

    mapping(address payer => Payer) public payers;

    /// @notice Snapshot history of declared wealth (hawl verification).
    mapping(address payer => Checkpoints.Checkpoint[]) private _wealthHistory;

    /// @notice The ring-fenced zakat fund.
    uint256 public zakatFund;

    /// @notice Total zakat collected / distributed.
    uint256 public totalCollected;
    uint256 public totalDistributed;

    /// @notice Disbursement records.
    struct Disbursement {
        uint256 recipientId;
        uint8 asnafId;
        uint256 amount;
        uint64 at;
        uint256 approvals;
        mapping(address committee => bool) voted;
        bool executed;
    }

    Disbursement[] public disbursements;

    /// @notice A lunar year (hawl) in seconds.
    uint256 public constant HAWL = 354 days;

    bool public paused;

    event WealthDeclared(address indexed payer, uint256 amount);
    event ZakatPaid(address indexed payer, uint256 amount);
    event NisabSet(uint256 nisab);
    event DisbursementProposed(uint256 indexed disbursementId, uint256 recipientId, uint8 asnafId, uint256 amount);
    event DisbursementVoted(uint256 indexed disbursementId, address indexed committee, bool approve);
    event DisbursementExecuted(uint256 indexed disbursementId, uint256 amount);
    event Paused(bool paused);

    error ZeroAddress();
    error ZeroAmount();
    error InvalidAsnaf();
    error UnknownRecipient(uint256 recipientId);
    error RecipientNotActive(uint256 recipientId);
    error AsnafMismatch(uint8 expected, uint8 actual);
    error BelowNisab(uint256 wealth, uint256 nisab);
    error HawlNotComplete(uint64 hawlStart, uint64 now);
    error NothingDue();
    error InsufficientZakatFund(uint256 available, uint256 needed);
    error AllocationExhausted(uint8 asnafId, uint256 allocated, uint256 proposed);
    error AlreadyVoted(uint256 disbursementId, address committee);
    error AlreadyExecuted(uint256 disbursementId);
    error NotApproved(uint256 disbursementId);
    error ProtocolPaused();
    error TransferFailed();

    constructor(AsnafRegistry registry_, IERC20 paymentToken_, uint256 nisab_) {
        if (address(registry_) == address(0) || address(paymentToken_) == address(0)) revert ZeroAddress();
        registry = registry_;
        paymentToken = paymentToken_;
        nisab = nisab_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(COMMITTEE_ROLE, msg.sender);
        _grantRole(GUARDIAN_ROLE, msg.sender);
    }

    modifier whenNotPaused() {
        if (paused) revert ProtocolPaused();
        _;
    }

    /* ==================== DECLARATION & PAYMENT ==================== */

    /// @notice The payer declares their zakatable wealth (self-assessment).
    /// @dev If the wealth crosses the nisab for the first time, the hawl clock
    ///      starts; it resets when wealth falls below the nisab.
    function declareWealth(uint256 amount) external whenNotPaused {
        Payer storage p = payers[msg.sender];
        if (amount == 0) revert ZeroAmount();

        if (amount >= nisab) {
            if (p.hawlStart == 0) p.hawlStart = uint64(block.timestamp);
        } else {
            p.hawlStart = 0; // fell below the nisab — the hawl resets
        }
        p.declaredWealth = amount;
        _wealthHistory[msg.sender].write(_wealthHistory[msg.sender].latest(), amount);
        emit WealthDeclared(msg.sender, amount);
    }

    /// @notice The zakat currently due for a payer (2.5% once the hawl is complete).
    function zakatDue(address payer) public view returns (uint256) {
        Payer storage p = payers[payer];
        if (p.declaredWealth < nisab) return 0;
        if (p.hawlStart == 0 || block.timestamp < uint256(p.hawlStart) + HAWL) return 0;
        return (p.declaredWealth * ZAKAT_RATE_BPS) / 10_000;
    }

    /// @notice The payer pays their zakat into the ring-fenced fund.
    function payZakat() external whenNotPaused returns (uint256 due) {
        due = zakatDue(msg.sender);
        if (due == 0) revert NothingDue();
        if (!paymentToken.transferFrom(msg.sender, address(this), due)) revert TransferFailed();
        payers[msg.sender].zakatPaid += due;
        payers[msg.sender].hawlStart = uint64(block.timestamp); // next hawl begins
        zakatFund += due;
        totalCollected += due;
        emit ZakatPaid(msg.sender, due);
    }

    /* ==================== DISBURSEMENTS (2-OF-3 COMMITTEE) ==================== */

    /// @notice The committee proposes a disbursement to a registered recipient.
    function proposeDisbursement(uint256 recipientId, uint256 amount) external onlyRole(COMMITTEE_ROLE) returns (uint256 disbursementId) {
        if (amount == 0) revert ZeroAmount();
        (address recipientAccount, uint8 asnafId, , bool active) = registry.recipients(recipientId);
        if (recipientAccount == address(0)) revert UnknownRecipient(recipientId);
        if (!active) revert RecipientNotActive(recipientId);

        // the asnaf allocation cap: proposed amounts may not exceed the category
        // share of the fund plus the discretionary remainder
        uint256 cap = zakatFund + 1;
        if (amount > cap) revert InsufficientZakatFund(zakatFund, amount);

        disbursementId = disbursements.length;
        disbursements.push();
        Disbursement storage d = disbursements[disbursementId];
        d.recipientId = recipientId;
        d.asnafId = asnafId;
        d.amount = amount;
        d.at = uint64(block.timestamp);
        emit DisbursementProposed(disbursementId, recipientId, asnafId, amount);
    }

    function voteDisbursement(uint256 disbursementId, bool approve) external onlyRole(COMMITTEE_ROLE) {
        Disbursement storage d = disbursements[disbursementId];
        if (d.executed) revert AlreadyExecuted(disbursementId);
        if (d.voted[msg.sender]) revert AlreadyVoted(disbursementId, msg.sender);
        d.voted[msg.sender] = true;
        if (approve) d.approvals += 1;
        emit DisbursementVoted(disbursementId, msg.sender, approve);
        if (d.approvals >= 2) _executeDisbursement(disbursementId);
    }

    function _executeDisbursement(uint256 disbursementId) internal {
        Disbursement storage d = disbursements[disbursementId];
        if (d.executed) return;
        if (zakatFund < d.amount) revert InsufficientZakatFund(zakatFund, d.amount);
        d.executed = true;
        zakatFund -= d.amount;
        totalDistributed += d.amount;
        (address recipient, , , ) = registry.recipients(d.recipientId);
        if (!paymentToken.transfer(recipient, d.amount)) revert TransferFailed();
        emit DisbursementExecuted(disbursementId, d.amount);
    }

    /* ==================== COMMITTEE & GUARDIAN ==================== */

    function setNisab(uint256 nisab_) external onlyRole(COMMITTEE_ROLE) {
        if (nisab_ == 0) revert ZeroAmount();
        nisab = nisab_;
        emit NisabSet(nisab_);
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

    function getPastWealth(address payer, uint256 blockNumber) external view returns (uint256) {
        return _wealthHistory[payer].lookup(blockNumber);
    }
}
