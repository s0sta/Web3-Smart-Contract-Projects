// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {ShifaRegistry} from "./ShifaRegistry.sol";
import {ShifaConsent} from "./ShifaConsent.sol";
import {ShifaScopes} from "./ShifaScopes.sol";

/// @title ShifaRecords
/// @notice The medical record index. The medical file itself lives off-chain;
///         the chain keeps the fingerprint (content hash), who wrote it, the
///         kind of record and the moment it was written, so nobody can change
///         history later. Reading a record requires the patient's consent — or
///         an emergency grant, which is logged separately.
contract ShifaRecords is AccessControl {
    /// @notice Kinds of medical records.
    enum Kind { Note, Lab, Imaging, Vaccination, Surgery, Allergy }

    /// @notice One record in the index.
    struct Record {
        address patient;
        address author; // doctor or clinic
        Kind kind;
        bytes32 contentHash; // the medical document fingerprint
        uint64 createdAt;
        bool amended;
    }

    Record[] public records;
    mapping(address patient => uint256[]) private _byPatient;

    ShifaRegistry public immutable registry;
    ShifaConsent public immutable consent;

    /// @notice A short note is attached to every write so the timeline reads well.
    string public constant DISCLAIMER = "Index only: the medical file stays off-chain with the patient.";

    event RecordCreated(uint256 indexed recordId, address indexed patient, address indexed author, Kind kind, bytes32 contentHash);
    event RecordAmended(uint256 indexed recordId, bytes32 newContentHash);
    event RecordRead(uint256 indexed recordId, address indexed reader);

    error ZeroAddress();
    error NotClinician();
    error UnknownRecord(uint256 recordId);
    error NotAuthor(uint256 recordId);
    error NotAllowedToRead(uint256 recordId, address reader);
    error EmptyHash();

    constructor(ShifaRegistry registry_, ShifaConsent consent_) {
        if (address(registry_) == address(0) || address(consent_) == address(0)) revert ZeroAddress();
        registry = registry_;
        consent = consent_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /* ==================== WRITING ==================== */

    /// @notice A clinician files a record for a patient.
    function createRecord(address patient, Kind kind, bytes32 contentHash) external returns (uint256 recordId) {
        if (!registry.isClinician(msg.sender)) revert NotClinician();
        if (!registry.isActive(patient)) revert NotAllowedToRead(0, patient);
        if (contentHash == bytes32(0)) revert EmptyHash();

        recordId = records.length;
        records.push();
        Record storage r = records[recordId];
        r.patient = patient;
        r.author = msg.sender;
        r.kind = kind;
        r.contentHash = contentHash;
        r.createdAt = uint64(block.timestamp);
        _byPatient[patient].push(recordId);
        emit RecordCreated(recordId, patient, msg.sender, kind, contentHash);
    }

    /// @notice The original author can amend the fingerprint (a correction is a
    ///         new hash, never an overwrite of the old one in the event log).
    function amendRecord(uint256 recordId, bytes32 newContentHash) external {
        Record storage r = records[recordId];
        if (r.patient == address(0)) revert UnknownRecord(recordId);
        if (r.author != msg.sender) revert NotAuthor(recordId);
        if (newContentHash == bytes32(0)) revert EmptyHash();
        r.contentHash = newContentHash;
        r.amended = true;
        emit RecordAmended(recordId, newContentHash);
    }

    /* ==================== READING ==================== */

    /// @notice Reads a record. Allowed for the patient, the author, a provider
    ///         holding the records scope, or a provider inside an emergency grant.
    function readRecord(uint256 recordId) external returns (bytes32 contentHash) {
        Record storage r = records[recordId];
        if (r.patient == address(0)) revert UnknownRecord(recordId);
        bool allowed = msg.sender == r.patient
            || msg.sender == r.author
            || consent.hasConsent(r.patient, msg.sender, ShifaScopes.RECORDS)
            || consent.hasConsent(r.patient, msg.sender, ShifaScopes.EMERGENCY);
        if (!allowed) revert NotAllowedToRead(recordId, msg.sender);
        emit RecordRead(recordId, msg.sender);
        return r.contentHash;
    }

    /// @notice Who may read, without touching state (used by the dApp).
    function canRead(uint256 recordId, address reader) public view returns (bool) {
        Record storage r = records[recordId];
        if (r.patient == address(0)) return false;
        if (reader == r.patient || reader == r.author) return true;
        return consent.hasConsent(r.patient, reader, ShifaScopes.RECORDS)
            || consent.hasConsent(r.patient, reader, ShifaScopes.EMERGENCY);
    }

    function recordsOf(address patient) external view returns (uint256[] memory) {
        return _byPatient[patient];
    }

    function recordCount() external view returns (uint256) {
        return records.length;
    }
}
