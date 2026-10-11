// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {ShifaRegistry} from "./ShifaRegistry.sol";
import {ShifaScopes} from "./ShifaScopes.sol";

/// @title ShifaConsent
/// @notice The patient's key to their own data. A patient grants a provider a
///         scope (records, prescriptions, insurance, emergency) for a limited
///         time, can revoke at any moment, and every grant or revocation is
///         recorded on-chain. Other Shifa contracts ask this one before they let
///         anyone read or write patient data.
contract ShifaConsent is AccessControl {
    /// @notice Scope bits (they combine).
    uint8 public constant SCOPE_RECORDS = ShifaScopes.RECORDS;
    uint8 public constant SCOPE_PRESCRIPTIONS = ShifaScopes.PRESCRIPTIONS;
    uint8 public constant SCOPE_INSURANCE = ShifaScopes.INSURANCE;
    uint8 public constant SCOPE_EMERGENCY = ShifaScopes.EMERGENCY;
    uint8 public constant SCOPE_ALL = ShifaScopes.ALL;

    /// @notice The emergency desk can mint a temporary emergency grant.
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY");

    /// @notice One grant.
    struct Grant {
        uint8 scope;
        uint64 grantedAt;
        uint64 expiresAt;
        bool active;
    }

    mapping(address patient => mapping(address provider => Grant)) public grants;
    mapping(address patient => address[]) private _providers;

    /// @notice How many grants a patient has handed out (for the dashboard).
    mapping(address patient => uint256) public grantCount;

    ShifaRegistry public immutable registry;

    event ConsentGranted(address indexed patient, address indexed provider, uint8 scope, uint64 expiresAt);
    event ConsentRevoked(address indexed patient, address indexed provider);
    event ConsentUsed(address indexed patient, address indexed provider, uint8 scope, address indexed user);

    error ZeroAddress();
    error NotPatient();
    error NotProvider();
    error EmptyScope();
    error ExpiryInPast();
    error NoConsent(address patient, address provider, uint8 scope);

    constructor(ShifaRegistry registry_) {
        if (address(registry_) == address(0)) revert ZeroAddress();
        registry = registry_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
    }

    /* ==================== PATIENT ACTIONS ==================== */

    function grant(address provider, uint8 scope, uint64 expiresAt) external {
        if (!registry.isActive(msg.sender)) revert NotPatient();
        if (!registry.isActive(provider)) revert NotProvider();
        if (scope == 0) revert EmptyScope();
        if (expiresAt <= block.timestamp) revert ExpiryInPast();

        if (!grants[msg.sender][provider].active) {
            _providers[msg.sender].push(provider);
            grantCount[msg.sender] += 1;
        }
        grants[msg.sender][provider] = Grant({
            scope: scope,
            grantedAt: uint64(block.timestamp),
            expiresAt: expiresAt,
            active: true
        });
        emit ConsentGranted(msg.sender, provider, scope, expiresAt);
    }

    function revoke(address provider) external {
        if (!grants[msg.sender][provider].active) revert NoConsent(msg.sender, provider, 0);
        delete grants[msg.sender][provider];
        emit ConsentRevoked(msg.sender, provider);
    }

    /// @notice The emergency desk opens a short-lived emergency grant. Patients
    ///         keep the audit trail and the governor can tighten the rules.
    function emergencyGrant(address patient, address provider, uint64 hoursValid) external onlyRole(EMERGENCY_ROLE) returns (uint64 expiresAt) {
        if (hoursValid == 0 || hoursValid > 72) revert ExpiryInPast();
        expiresAt = uint64(block.timestamp + uint256(hoursValid) * 1 hours);
        grants[patient][provider] = Grant({
            scope: SCOPE_EMERGENCY | SCOPE_RECORDS,
            grantedAt: uint64(block.timestamp),
            expiresAt: expiresAt,
            active: true
        });
        emit ConsentGranted(patient, provider, SCOPE_EMERGENCY | SCOPE_RECORDS, expiresAt);
    }

    /* ==================== QUERIES ==================== */

    /// @notice True when the provider holds the scope and the grant has not expired.
    function hasConsent(address patient, address provider, uint8 scope) public view returns (bool) {
        Grant storage g = grants[patient][provider];
        if (!g.active) return false;
        if (g.expiresAt <= block.timestamp) return false;
        return (g.scope & scope) == scope;
    }

    /// @notice Used by other contracts: revert when the provider may not act.
    function requireConsent(address patient, address provider, uint8 scope) external view {
        if (!hasConsent(patient, provider, scope)) revert NoConsent(patient, provider, scope);
    }

    /// @notice Records that a provider actually read or wrote patient data.
    ///         Kept as a separate call so access logs stay readable on Etherscan.
    function logAccess(address patient, address provider, uint8 scope) external {
        if (!hasConsent(patient, provider, scope)) revert NoConsent(patient, provider, scope);
        emit ConsentUsed(patient, provider, scope, msg.sender);
    }

    function providersOfList(address patient) external view returns (address[] memory) {
        return _providers[patient];
    }
}
