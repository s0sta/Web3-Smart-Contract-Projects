// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";

/// @title ShifaRegistry
/// @notice The healthcare directory: patients, doctors, clinics, pharmacists and
///         insurers. Each provider carries a license hash so the dApp can prove
///         who is allowed to practise, and compliance can freeze or sanction any
///         account.
contract ShifaRegistry is AccessControl {
    /// @notice Compliance officers manage the directory.
    bytes32 public constant OFFICER_ROLE = keccak256("OFFICER");

    /// @notice Who is registered.
    enum Role { None, Patient, Doctor, Clinic, Pharmacist, Insurer }

    /// @notice KYC level. Verified is required for providers and insurers.
    enum KycTier { None, Basic, Verified }

    /// @notice One account in the directory.
    struct Member {
        Role role;
        KycTier tier;
        bytes32 licenseHash; // empty for patients
        uint64 region;
        bool sanctioned;
        bool frozen;
        uint64 registeredAt;
    }

    mapping(address account => Member) public members;
    uint256 public memberCount;

    event Registered(address indexed account, Role role, KycTier tier, uint64 region);
    event RoleSet(address indexed account, Role role);
    event KycSet(address indexed account, KycTier tier);
    event LicenseSet(address indexed account, bytes32 licenseHash);
    event SanctionSet(address indexed account, bool sanctioned);
    event AccountFrozen(address indexed account, bool frozen);

    error ZeroAddress();
    error NotOfficer();
    error UnknownAccount(address account);
    error AlreadyRegistered(address account);
    error WrongRole(address account, Role expected);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OFFICER_ROLE, msg.sender);
    }

    modifier onlyOfficer() {
        if (!hasRole(OFFICER_ROLE, msg.sender)) revert NotOfficer();
        _;
    }

    modifier known(address account) {
        if (members[account].registeredAt == 0) revert UnknownAccount(account);
        _;
    }

    /* ==================== REGISTRATION ==================== */

    function register(Role role, uint64 region, bytes32 licenseHash) external returns (address account) {
        account = msg.sender;
        if (role == Role.None) revert ZeroAddress();
        if (members[account].registeredAt != 0) revert AlreadyRegistered(account);
        members[account] = Member({
            role: role,
            tier: KycTier.Basic,
            licenseHash: licenseHash,
            region: region,
            sanctioned: false,
            frozen: false,
            registeredAt: uint64(block.timestamp)
        });
        memberCount += 1;
        emit Registered(account, role, KycTier.Basic, region);
    }

    function setRole(address account, Role role) external onlyOfficer known(account) {
        members[account].role = role;
        emit RoleSet(account, role);
    }

    function setKyc(address account, KycTier tier) external onlyOfficer known(account) {
        members[account].tier = tier;
        emit KycSet(account, tier);
    }

    function setLicense(address account, bytes32 licenseHash) external onlyOfficer known(account) {
        members[account].licenseHash = licenseHash;
        emit LicenseSet(account, licenseHash);
    }

    function setSanctioned(address account, bool sanctioned_) external onlyOfficer known(account) {
        members[account].sanctioned = sanctioned_;
        emit SanctionSet(account, sanctioned_);
    }

    function setFrozen(address account, bool frozen) external onlyOfficer known(account) {
        members[account].frozen = frozen;
        emit AccountFrozen(account, frozen);
    }

    /* ==================== QUERIES ==================== */

    function isActive(address account) public view returns (bool) {
        Member storage m = members[account];
        return m.registeredAt != 0 && !m.sanctioned && !m.frozen;
    }

    /// @notice A verified, active provider (doctor, clinic, pharmacist or insurer).
    function isVerifiedProvider(address account) public view returns (bool) {
        Member storage m = members[account];
        if (m.registeredAt == 0 || m.sanctioned || m.frozen) return false;
        if (m.tier != KycTier.Verified) return false;
        return m.role == Role.Doctor || m.role == Role.Clinic || m.role == Role.Pharmacist || m.role == Role.Insurer;
    }

    function isClinician(address account) public view returns (bool) {
        Member storage m = members[account];
        if (!isVerifiedProvider(account)) return false;
        return m.role == Role.Doctor || m.role == Role.Clinic;
    }

    function roleOf(address account) external view returns (Role) {
        return members[account].role;
    }

    function requireRole(address account, Role expected) external view {
        if (members[account].role != expected) revert WrongRole(account, expected);
    }
}
