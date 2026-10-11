// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {ShifaRegistry} from "./ShifaRegistry.sol";
import {ShifaConsent} from "./ShifaConsent.sol";
import {ShifaScopes} from "./ShifaScopes.sol";

/// @title ShifaPrescriptions
/// @notice Electronic prescriptions. A doctor writes the prescription on-chain
///         (the drug is a hash, so the medicine name stays private if the clinic
///         wants that), the pharmacy dispenses it against the patient's
///         prescriptions consent, refills are counted, controlled medicines have
///         a hard refill cap, and expired prescriptions cannot be filled.
contract ShifaPrescriptions is AccessControl {
    /// @notice One prescription.
    struct Prescription {
        address patient;
        address doctor;
        bytes32 drugHash;
        uint16 doseMg;
        uint8 refillsAllowed;
        uint8 refillsUsed;
        uint64 issuedAt;
        uint64 expiresAt;
        bool controlled;
        bool canceled;
    }

    Prescription[] public prescriptions;
    mapping(address patient => uint256[]) private _byPatient;
    mapping(address pharmacy => uint256[]) private _dispensedBy;

    /// @notice Controlled medicines may be refilled at most this many times.
    uint8 public controlledRefillCap;

    ShifaRegistry public immutable registry;
    ShifaConsent public immutable consent;

    event PrescriptionIssued(uint256 indexed rxId, address indexed patient, address indexed doctor, bytes32 drugHash, uint8 refills, bool controlled);
    event PrescriptionDispensed(uint256 indexed rxId, address indexed pharmacy, uint8 refillsUsed);
    event PrescriptionCanceled(uint256 indexed rxId);

    error ZeroAddress();
    error NotClinician();
    error NotPharmacist();
    error UnknownPrescription(uint256 rxId);
    error NotAllowed(uint256 rxId, address caller);
    error ExpiredPrescription(uint256 rxId, uint64 expiresAt);
    error NoRefillsLeft(uint256 rxId);
    error ControlledLimit(uint256 rxId, uint8 cap);
    error CanceledPrescription(uint256 rxId);
    error EmptyHash();

    constructor(ShifaRegistry registry_, ShifaConsent consent_, uint8 controlledRefillCap_) {
        if (address(registry_) == address(0) || address(consent_) == address(0)) revert ZeroAddress();
        registry = registry_;
        consent = consent_;
        controlledRefillCap = controlledRefillCap_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /* ==================== ISSUING ==================== */

    function issue(
        address patient,
        bytes32 drugHash,
        uint16 doseMg,
        uint8 refillsAllowed,
        uint64 validityDays,
        bool controlled
    ) external returns (uint256 rxId) {
        if (!registry.isClinician(msg.sender)) revert NotClinician();
        if (!registry.isActive(patient)) revert NotAllowed(0, patient);
        if (drugHash == bytes32(0)) revert EmptyHash();
        if (validityDays == 0 || validityDays > 180) revert ExpiredPrescription(0, 0);
        if (controlled && refillsAllowed > controlledRefillCap) revert ControlledLimit(0, controlledRefillCap);

        rxId = prescriptions.length;
        prescriptions.push();
        Prescription storage p = prescriptions[rxId];
        p.patient = patient;
        p.doctor = msg.sender;
        p.drugHash = drugHash;
        p.doseMg = doseMg;
        p.refillsAllowed = refillsAllowed;
        p.issuedAt = uint64(block.timestamp);
        p.expiresAt = uint64(block.timestamp + uint256(validityDays) * 1 days);
        p.controlled = controlled;
        _byPatient[patient].push(rxId);
        emit PrescriptionIssued(rxId, patient, msg.sender, drugHash, refillsAllowed, controlled);
    }

    function cancel(uint256 rxId) external {
        Prescription storage p = prescriptions[rxId];
        if (p.patient == address(0)) revert UnknownPrescription(rxId);
        if (msg.sender != p.doctor) revert NotAllowed(rxId, msg.sender);
        p.canceled = true;
        emit PrescriptionCanceled(rxId);
    }

    /* ==================== DISPENSING ==================== */

    /// @notice The pharmacy fills the prescription. The patient must have given
    ///         the prescriptions scope (or an emergency grant) to that pharmacy.
    function dispense(uint256 rxId) external {
        Prescription storage p = prescriptions[rxId];
        if (p.patient == address(0)) revert UnknownPrescription(rxId);
        if (!registry.isVerifiedProvider(msg.sender) || registry.roleOf(msg.sender) != ShifaRegistry.Role.Pharmacist) {
            revert NotPharmacist();
        }
        if (p.canceled) revert CanceledPrescription(rxId);
        if (block.timestamp > p.expiresAt) revert ExpiredPrescription(rxId, p.expiresAt);
        if (p.refillsUsed >= p.refillsAllowed) revert NoRefillsLeft(rxId);

        bool allowed = consent.hasConsent(p.patient, msg.sender, ShifaScopes.PRESCRIPTIONS)
            || consent.hasConsent(p.patient, msg.sender, ShifaScopes.EMERGENCY);
        if (!allowed) revert NotAllowed(rxId, msg.sender);

        p.refillsUsed += 1;
        _dispensedBy[msg.sender].push(rxId);
        emit PrescriptionDispensed(rxId, msg.sender, p.refillsUsed);
    }

    /* ==================== QUERIES ==================== */

    function refillsLeft(uint256 rxId) external view returns (uint256) {
        Prescription storage p = prescriptions[rxId];
        if (p.patient == address(0)) revert UnknownPrescription(rxId);
        if (block.timestamp > p.expiresAt) return 0;
        return uint256(p.refillsAllowed) - uint256(p.refillsUsed);
    }

    function prescriptionsOf(address patient) external view returns (uint256[] memory) {
        return _byPatient[patient];
    }

    function dispensedBy(address pharmacy) external view returns (uint256[] memory) {
        return _dispensedBy[pharmacy];
    }

    function prescriptionCount() external view returns (uint256) {
        return prescriptions.length;
    }

    /* ==================== ADMIN ==================== */

    function setControlledRefillCap(uint8 cap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (cap > 12) revert ControlledLimit(0, cap);
        controlledRefillCap = cap;
    }
}
