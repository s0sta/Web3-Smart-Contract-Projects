// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {ShifaRegistry} from "./ShifaRegistry.sol";
import {ShifaConsent} from "./ShifaConsent.sol";

/// @title ShifaEmergency
/// @notice Break-glass access. In a real emergency a clinician must be able to
///         open a patient's file without waiting for consent — so the platform
///         allows it, but it expires by itself (at most 72 hours), it opens only
///         the emergency + records scopes, and a reviewer must confirm afterwards
///         that the emergency was real. Nothing is silent.
contract ShifaEmergency is AccessControl {
    /// @notice Reviewers audit every break-glass case.
    bytes32 public constant REVIEWER_ROLE = keccak256("REVIEWER");

    /// @notice One emergency access case.
    struct Case {
        address patient;
        address requester; // the clinician who opened it
        string reason;
        uint64 startedAt;
        uint64 expiresAt;
        bool reviewed;
        bool upheld; // true = real emergency, false = misuse
    }

    Case[] public cases;
    mapping(address patient => uint256[]) private _byPatient;

    /// @notice When true, a clinician may only break the glass after the patient
    ///         has a consent record at all (a light anti-abuse switch).
    bool public requireExistingRelationship;

    ShifaRegistry public immutable registry;
    ShifaConsent public immutable consent;

    event BreakGlassOpened(uint256 indexed caseId, address indexed patient, address indexed requester, string reason, uint64 expiresAt);
    event BreakGlassReviewed(uint256 indexed caseId, address indexed reviewer, bool upheld);
    event CaseReviewed(uint256 indexed caseId, bool upheld);

    error ZeroAddress();
    error NotClinician();
    error UnknownCase(uint256 caseId);
    error NotReviewer();
    error AlreadyReviewed(uint256 caseId);
    error PatientInactive(address patient);
    error DurationTooLong(uint64 hoursRequested, uint64 maxHours);

    constructor(ShifaRegistry registry_, ShifaConsent consent_) {
        if (address(registry_) == address(0) || address(consent_) == address(0)) revert ZeroAddress();
        registry = registry_;
        consent = consent_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(REVIEWER_ROLE, msg.sender);
    }

    /* ==================== BREAK GLASS ==================== */

    /// @notice Opens temporary emergency access for a clinician. The consent
    ///         contract mints the matching grant so records and prescriptions
    ///         become readable for the window.
    function openCase(address patient, string calldata reason, uint64 hoursValid) external returns (uint256 caseId, uint64 expiresAt) {
        if (!registry.isClinician(msg.sender)) revert NotClinician();
        if (!registry.isActive(patient)) revert PatientInactive(patient);
        if (hoursValid == 0 || hoursValid > 72) revert DurationTooLong(hoursValid, 72);

        expiresAt = consent.emergencyGrant(patient, msg.sender, hoursValid);
        caseId = cases.length;
        cases.push();
        Case storage c = cases[caseId];
        c.patient = patient;
        c.requester = msg.sender;
        c.reason = reason;
        c.startedAt = uint64(block.timestamp);
        c.expiresAt = expiresAt;
        _byPatient[patient].push(caseId);
        emit BreakGlassOpened(caseId, patient, msg.sender, reason, expiresAt);
    }

    /// @notice A reviewer confirms the emergency was genuine, or flags misuse.
    function review(uint256 caseId, bool upheld) external onlyRole(REVIEWER_ROLE) {
        Case storage c = cases[caseId];
        if (c.patient == address(0)) revert UnknownCase(caseId);
        if (c.reviewed) revert AlreadyReviewed(caseId);
        c.reviewed = true;
        c.upheld = upheld;
        emit BreakGlassReviewed(caseId, msg.sender, upheld);
        emit CaseReviewed(caseId, upheld);
    }

    /* ==================== QUERIES ==================== */

    function isOpen(uint256 caseId) public view returns (bool) {
        Case storage c = cases[caseId];
        return c.patient != address(0) && block.timestamp < c.expiresAt;
    }

    function casesOf(address patient) external view returns (uint256[] memory) {
        return _byPatient[patient];
    }

    function caseCount() external view returns (uint256) {
        return cases.length;
    }

    /* ==================== ADMIN ==================== */

    function setRequireExistingRelationship(bool required) external onlyRole(DEFAULT_ADMIN_ROLE) {
        requireExistingRelationship = required;
    }
}
