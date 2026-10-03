// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";

/// @title AsnafRegistry
/// @notice The eight asnaf (Quran 9:60 — the categories entitled to zakat) and the
///         registered recipients. The zakat committee sets each category's allocation
///         ratio (basis points, summing to 10,000) and registers KYC'd recipients
///         with a proof-of-eligibility hash.
contract AsnafRegistry is AccessControl {
    /// @notice The zakat committee (3 members, 2-of-3 for disbursements).
    bytes32 public constant COMMITTEE_ROLE = keccak256("COMMITTEE");

    /// @notice The ZakatEngine (grants disbursement access).
    bytes32 public constant ENGINE_ROLE = keccak256("ENGINE");

    /// @notice The eight asnaf, in the Quranic order (Quran 9:60).
    function asnafName(uint8 asnafId) public pure returns (string memory) {
        if (asnafId == 0) return "Fuqara (the poor)";
        if (asnafId == 1) return "Masakin (the needy)";
        if (asnafId == 2) return "Amil (zakat administrators)";
        if (asnafId == 3) return "Muallaf (recent converts)";
        if (asnafId == 4) return "Riqab (freeing captives)";
        if (asnafId == 5) return "Gharimin (those in debt)";
        if (asnafId == 6) return "Fi Sabilillah (in the path of Allah)";
        if (asnafId == 7) return "Ibn Sabil (the stranded traveler)";
        return "";
    }

    /// @notice Allocation ratios in bps (sum must be ≤ 10,000; the remainder is
    ///         discretionary for the committee).
    mapping(uint8 asnafId => uint256) public allocations;

    /// @notice Total allocated bps.
    uint256 public totalAllocation;

    /// @notice One registered recipient.
    struct Recipient {
        address account;
        uint8 asnafId;
        bytes32 proofHash; // eligibility documentation (KYC, assessment)
        bool active;
    }

    Recipient[] public recipients;

    event AllocationSet(uint8 indexed asnafId, uint256 bps);
    event RecipientRegistered(uint256 indexed recipientId, address indexed account, uint8 asnafId, bytes32 proofHash);
    event RecipientDeactivated(uint256 indexed recipientId);

    error ZeroAddress();
    error InvalidAsnaf();
    error AllocationOverflow();
    error UnknownRecipient(uint256 recipientId);
    error NotActive(uint256 recipientId);
    error InvalidProof();

    constructor(address[] memory committeeMembers) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(COMMITTEE_ROLE, msg.sender);
        for (uint256 i = 0; i < committeeMembers.length; i++) {
            if (committeeMembers[i] == address(0)) revert ZeroAddress();
            _grantRole(COMMITTEE_ROLE, committeeMembers[i]);
        }
    }

    /* ==================== ALLOCATIONS ==================== */

    function setAllocation(uint8 asnafId, uint256 bps) external onlyRole(COMMITTEE_ROLE) {
        if (asnafId > 7) revert InvalidAsnaf();
        if (bps > 10_000) revert AllocationOverflow();
        uint256 newTotal = totalAllocation - allocations[asnafId] + bps;
        if (newTotal > 10_000) revert AllocationOverflow();
        totalAllocation = newTotal;
        allocations[asnafId] = bps;
        emit AllocationSet(asnafId, bps);
    }

    /* ==================== RECIPIENTS ==================== */

    function registerRecipient(address account, uint8 asnafId, bytes32 proofHash) external onlyRole(COMMITTEE_ROLE) returns (uint256 recipientId) {
        if (account == address(0)) revert ZeroAddress();
        if (asnafId > 7) revert InvalidAsnaf();
        if (proofHash == bytes32(0)) revert InvalidProof();
        recipientId = recipients.length;
        recipients.push(Recipient({ account: account, asnafId: asnafId, proofHash: proofHash, active: true }));
        emit RecipientRegistered(recipientId, account, asnafId, proofHash);
    }

    function deactivateRecipient(uint256 recipientId) external onlyRole(COMMITTEE_ROLE) {
        if (recipientId >= recipients.length) revert UnknownRecipient(recipientId);
        if (!recipients[recipientId].active) revert NotActive(recipientId);
        recipients[recipientId].active = false;
        emit RecipientDeactivated(recipientId);
    }

    function setEngine(address engine) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (engine == address(0)) revert ZeroAddress();
        _grantRole(ENGINE_ROLE, engine);
    }

    /// @notice Active recipients of one asnaf, for disbursement rounds.
    function recipientsOf(uint8 asnafId) external view returns (uint256[] memory ids) {
        uint256 count = 0;
        for (uint256 i = 0; i < recipients.length; i++) {
            if (recipients[i].active && recipients[i].asnafId == asnafId) count++;
        }
        ids = new uint256[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < recipients.length; i++) {
            if (recipients[i].active && recipients[i].asnafId == asnafId) {
                ids[idx] = i;
                idx++;
            }
        }
    }
}
