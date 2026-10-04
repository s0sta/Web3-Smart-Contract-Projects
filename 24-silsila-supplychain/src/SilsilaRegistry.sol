// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";

/// @title SilsilaRegistry
/// @notice The network's business directory: every participant is an entity
///         with a role (buyer, supplier, carrier, auditor, financier), a KYC
///         tier, a home region and sanction/freeze flags.
contract SilsilaRegistry is AccessControl {
    /// @notice Compliance officers manage entities.
    bytes32 public constant OFFICER_ROLE = keccak256("OFFICER");

    /// @notice Entity roles.
    enum Role { None, Buyer, Supplier, Carrier, Auditor, Financier }

    /// @notice KYC tiers.
    enum KycTier { None, Basic, Verified }

    /// @notice One business entity.
    struct Entity {
        Role role;
        KycTier tier;
        uint64 region;
        bool sanctioned;
        bool frozen;
        uint64 registeredAt;
    }

    mapping(address entity => Entity) public entities;
    uint256 public entityCount;

    event EntityRegistered(address indexed entity, Role role, KycTier tier, uint64 region);
    event EntityUpdated(address indexed entity, Role role, KycTier tier);
    event SanctionSet(address indexed entity, bool sanctioned);
    event EntityFrozen(address indexed entity, bool frozen);

    error ZeroAddress();
    error NotOfficer();
    error UnknownEntity(address entity);
    error AlreadyRegistered(address entity);
    error InactiveEntity(address entity);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OFFICER_ROLE, msg.sender);
    }

    modifier onlyOfficer() {
        if (!hasRole(OFFICER_ROLE, msg.sender)) revert NotOfficer();
        _;
    }

    /* ==================== REGISTRATION ==================== */

    function register(Role role, uint64 region) external returns (address entity) {
        entity = msg.sender;
        if (role == Role.None) revert ZeroAddress();
        if (entities[entity].registeredAt != 0) revert AlreadyRegistered(entity);
        entities[entity] = Entity({
            role: role,
            tier: KycTier.Basic,
            region: region,
            sanctioned: false,
            frozen: false,
            registeredAt: uint64(block.timestamp)
        });
        entityCount += 1;
        emit EntityRegistered(entity, role, KycTier.Basic, region);
    }

    function setRole(address entity, Role role) external onlyOfficer {
        if (entities[entity].registeredAt == 0) revert UnknownEntity(entity);
        entities[entity].role = role;
        emit EntityUpdated(entity, role, entities[entity].tier);
    }

    function setKyc(address entity, KycTier tier) external onlyOfficer {
        if (entities[entity].registeredAt == 0) revert UnknownEntity(entity);
        entities[entity].tier = tier;
        emit EntityUpdated(entity, entities[entity].role, tier);
    }

    function setSanctioned(address entity, bool sanctioned_) external onlyOfficer {
        if (entities[entity].registeredAt == 0) revert UnknownEntity(entity);
        entities[entity].sanctioned = sanctioned_;
        emit SanctionSet(entity, sanctioned_);
    }

    function setFrozen(address entity, bool frozen) external onlyOfficer {
        if (entities[entity].registeredAt == 0) revert UnknownEntity(entity);
        entities[entity].frozen = frozen;
        emit EntityFrozen(entity, frozen);
    }

    /* ==================== QUERIES ==================== */

    function isActive(address entity) external view returns (bool) {
        Entity storage e = entities[entity];
        return e.registeredAt != 0 && !e.sanctioned && !e.frozen;
    }

    function roleOf(address entity) external view returns (Role) {
        return entities[entity].role;
    }

    function regionOf(address entity) external view returns (uint64) {
        return entities[entity].region;
    }
}
