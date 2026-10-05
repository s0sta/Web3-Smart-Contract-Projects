// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";

/// @title DamanRegistry
/// @notice The participant directory: policyholders, underwriters and adjusters
///         with KYC tiers, sanctions and freeze flags.
contract DamanRegistry is AccessControl {
    /// @notice Compliance officers manage participants.
    bytes32 public constant OFFICER_ROLE = keccak256("OFFICER");

    /// @notice Participant roles.
    enum Role { None, Policyholder, Underwriter, Adjuster }

    /// @notice KYC tiers.
    enum KycTier { None, Basic, Verified }

    /// @notice One participant.
    struct Participant {
        Role role;
        KycTier tier;
        bool sanctioned;
        bool frozen;
        uint64 registeredAt;
    }

    mapping(address participant => Participant) public participants;
    uint256 public participantCount;

    event Registered(address indexed participant, Role role, KycTier tier);
    event RoleSet(address indexed participant, Role role);
    event KycSet(address indexed participant, KycTier tier);
    event SanctionSet(address indexed participant, bool sanctioned);
    event ParticipantFrozen(address indexed participant, bool frozen);

    error ZeroAddress();
    error NotOfficer();
    error UnknownParticipant(address participant);
    error AlreadyRegistered(address participant);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OFFICER_ROLE, msg.sender);
    }

    modifier onlyOfficer() {
        if (!hasRole(OFFICER_ROLE, msg.sender)) revert NotOfficer();
        _;
    }

    /* ==================== REGISTRATION ==================== */

    function register(Role role) external returns (address participant) {
        participant = msg.sender;
        if (role == Role.None) revert ZeroAddress();
        if (participants[participant].registeredAt != 0) revert AlreadyRegistered(participant);
        participants[participant] = Participant({
            role: role,
            tier: KycTier.Basic,
            sanctioned: false,
            frozen: false,
            registeredAt: uint64(block.timestamp)
        });
        participantCount += 1;
        emit Registered(participant, role, KycTier.Basic);
    }

    function setRole(address participant, Role role) external onlyOfficer {
        if (participants[participant].registeredAt == 0) revert UnknownParticipant(participant);
        participants[participant].role = role;
        emit RoleSet(participant, role);
    }

    function setKyc(address participant, KycTier tier) external onlyOfficer {
        if (participants[participant].registeredAt == 0) revert UnknownParticipant(participant);
        participants[participant].tier = tier;
        emit KycSet(participant, tier);
    }

    function setSanctioned(address participant, bool sanctioned_) external onlyOfficer {
        if (participants[participant].registeredAt == 0) revert UnknownParticipant(participant);
        participants[participant].sanctioned = sanctioned_;
        emit SanctionSet(participant, sanctioned_);
    }

    function setFrozen(address participant, bool frozen) external onlyOfficer {
        if (participants[participant].registeredAt == 0) revert UnknownParticipant(participant);
        participants[participant].frozen = frozen;
        emit ParticipantFrozen(participant, frozen);
    }

    function isActive(address participant) external view returns (bool) {
        Participant storage p = participants[participant];
        return p.registeredAt != 0 && !p.sanctioned && !p.frozen;
    }

    function roleOf(address participant) external view returns (Role) {
        return participants[participant].role;
    }
}
