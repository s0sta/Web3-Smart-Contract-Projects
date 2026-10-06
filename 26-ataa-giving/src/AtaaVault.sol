// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {AtaaZakat} from "./AtaaZakat.sol";

/// @title AtaaVault
/// @notice The pooled giving fund with donor provenance: every contribution is
///         tracked; when the committee allocates funds, the outflow is
///         attributed to contributions in FIFO order, so every donor can see
///         exactly which disbursements their money funded.
contract AtaaVault is AccessControl {
    /// @notice The allocations desk records disbursements.
    bytes32 public constant ALLOCATIONS_ROLE = keccak256("ALLOCATIONS");

    /// @notice One contribution (zakat or sadaqa).
    struct Contribution {
        address donor;
        uint256 amount;
        uint256 allocated; // how much has been attributed to outflows
        AtaaZakat.AssetClass zakatClass; // None = general sadaqa
        uint64 createdAt;
    }

    Contribution[] public contributions;
    mapping(address donor => uint256[]) public contributionsOf;

    /// @notice One outflow: a slice of a contribution funding a disbursement.
    struct Outflow {
        uint256 contributionId;
        uint256 beneficiaryId;
        uint256 amount;
        uint64 date;
        string purpose;
    }

    Outflow[] public outflows;
    mapping(uint256 contributionId => uint256[]) public outflowsOf;

    /// @notice FIFO cursor: the next contribution to draw from.
    uint256 public fifoCursor;

    uint256 public totalIn;
    uint256 public totalOut;

    IERC20 public immutable paymentToken;

    event ContributionMade(uint256 indexed contributionId, address indexed donor, uint256 amount, AtaaZakat.AssetClass zakatClass);
    event Disbursed(uint256 indexed beneficiaryId, uint256 amount, string purpose);
    event OutflowRecorded(uint256 indexed outflowId, uint256 contributionId, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownContribution(uint256 contributionId);
    error NotAllocationsDesk();
    error InsufficientPool(uint256 available, uint256 needed);
    error TransferFailed();

    constructor(IERC20 paymentToken_) {
        if (address(paymentToken_) == address(0)) revert ZeroAddress();
        paymentToken = paymentToken_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ALLOCATIONS_ROLE, msg.sender);
    }

    /* ==================== INFLOWS ==================== */

    /// @notice Records a general sadaqa contribution (tokens arrive via the
    ///         donations desk or directly).
    function recordDonation(address donor, uint256 amount) external onlyRole(ALLOCATIONS_ROLE) returns (uint256 contributionId) {
        return _record(donor, amount, AtaaZakat.AssetClass.None);
    }

    /// @notice The zakat module records a zakat payment.
    function recordZakat(address donor, AtaaZakat.AssetClass ac, uint256 amount) external returns (uint256 contributionId) {
        // the zakat module is the only external caller; validated by its role
        if (!hasRole(ALLOCATIONS_ROLE, msg.sender) && msg.sender != address(zakat)) revert NotAllocationsDesk();
        return _record(donor, amount, ac);
    }

    function _record(address donor, uint256 amount, AtaaZakat.AssetClass ac) internal returns (uint256 contributionId) {
        if (donor == address(0) || amount == 0) revert ZeroAmount();
        contributionId = contributions.length;
        contributions.push();
        Contribution storage c = contributions[contributionId];
        c.donor = donor;
        c.amount = amount;
        c.zakatClass = ac;
        c.createdAt = uint64(block.timestamp);
        contributionsOf[donor].push(contributionId);
        totalIn += amount;
        emit ContributionMade(contributionId, donor, amount, ac);
    }

    /* ==================== OUTFLOWS WITH PROVENANCE ==================== */

    /// @notice The allocations desk disburses to a beneficiary's wallet; the
    ///         outflow is attributed across contributions FIFO.
    function disburse(uint256 beneficiaryId, address beneficiaryWallet, uint256 amount, string calldata purpose) external onlyRole(ALLOCATIONS_ROLE) returns (uint256) {
        if (amount == 0) revert ZeroAmount();
        uint256 available = totalIn - totalOut;
        if (available < amount) revert InsufficientPool(available, amount);

        uint256 remaining = amount;
        uint256 n = contributions.length;
        while (remaining > 0 && fifoCursor < n) {
            Contribution storage c = contributions[fifoCursor];
            uint256 free = c.amount - c.allocated;
            if (free == 0) {
                fifoCursor += 1;
                continue;
            }
            uint256 slice = free < remaining ? free : remaining;
            c.allocated += slice;
            remaining -= slice;
            outflows.push(Outflow({
                contributionId: fifoCursor,
                beneficiaryId: beneficiaryId,
                amount: slice,
                date: uint64(block.timestamp),
                purpose: purpose
            }));
            outflowsOf[fifoCursor].push(outflows.length - 1);
            emit OutflowRecorded(outflows.length - 1, fifoCursor, slice);
        }
        if (remaining > 0) revert InsufficientPool(available, amount);

        totalOut += amount;
        if (beneficiaryWallet != address(0)) {
            if (!paymentToken.transfer(beneficiaryWallet, amount)) revert TransferFailed();
        }
        emit Disbursed(beneficiaryId, amount, purpose);
        return amount;
    }

    /// @notice Pulls the pooled tokens to the allocations desk for forwarding.
    function withdrawTo(address to, uint256 amount) external onlyRole(ALLOCATIONS_ROLE) {
        if (amount == 0) revert ZeroAmount();
        uint256 available = totalIn - totalOut;
        if (available < amount) revert InsufficientPool(available, amount);
        if (!paymentToken.transfer(to, amount)) revert TransferFailed();
    }

    /* ==================== REPORTS ==================== */

    /// @notice The donor's full report: contributions, where each went, and
    ///         the still-unallocated remainder.
    function donorReport(address donor)
        external
        view
        returns (
            uint256 totalGiven,
            uint256 totalAllocated,
            uint256 totalUnallocated,
            uint256[] memory ids,
            uint256[] memory amounts,
            uint256[] memory allocatedAmounts
        )
    {
        ids = contributionsOf[donor];
        amounts = new uint256[](ids.length);
        allocatedAmounts = new uint256[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            Contribution storage c = contributions[ids[i]];
            totalGiven += c.amount;
            totalAllocated += c.allocated;
            amounts[i] = c.amount;
            allocatedAmounts[i] = c.allocated;
        }
        totalUnallocated = totalGiven - totalAllocated;
    }

    function outflowsOfList(uint256 contributionId) external view returns (uint256[] memory) {
        return outflowsOf[contributionId];
    }

    function poolBalance() external view returns (uint256) {
        return totalIn - totalOut;
    }

    AtaaZakat public zakat;

    function setZakatModule(AtaaZakat zakat_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(zakat_) == address(0)) revert ZeroAddress();
        zakat = zakat_;
    }
}
