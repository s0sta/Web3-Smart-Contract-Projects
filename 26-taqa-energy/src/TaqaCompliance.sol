// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {TaqaRegistry} from "./TaqaRegistry.sol";

/// @title TaqaCompliance
/// @notice The market rulebook: energy-zone allowlists, sanction screening
///         and participant activity checks for every trade leg.
contract TaqaCompliance is AccessControl {
    /// @notice Compliance officers manage zones.
    bytes32 public constant OFFICER_ROLE = keccak256("OFFICER");

    /// @notice Zones where energy may flow.
    mapping(uint64 zone => bool) public zoneAllowed;

    TaqaRegistry public immutable registry;

    event ZoneSet(uint64 indexed zone, bool allowed);

    error ZeroAddress();
    error NotOfficer();
    error InactiveParty(address party);
    error ZoneBlocked(uint64 zone);
    error WrongRole(address party, TaqaRegistry.Role expected);

    constructor(TaqaRegistry registry_) {
        if (address(registry_) == address(0)) revert ZeroAddress();
        registry = registry_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OFFICER_ROLE, msg.sender);
    }

    modifier onlyOfficer() {
        if (!hasRole(OFFICER_ROLE, msg.sender)) revert NotOfficer();
        _;
    }

    function setZoneAllowed(uint64 zone, bool allowed) external onlyOfficer {
        zoneAllowed[zone] = allowed;
        emit ZoneSet(zone, allowed);
    }

    function validateParties(address a, address b) external view {
        if (!registry.isActive(a)) revert InactiveParty(a);
        if (!registry.isActive(b)) revert InactiveParty(b);
    }

    /// @notice Validates an energy flow between two zones.
    function validateTrade(address producer, address consumer) external view {
        if (!registry.isActive(producer)) revert InactiveParty(producer);
        if (!registry.isActive(consumer)) revert InactiveParty(consumer);
        uint64 producerZone = registry.zoneOf(producer);
        uint64 consumerZone = registry.zoneOf(consumer);
        if (!zoneAllowed[producerZone] || !zoneAllowed[consumerZone]) {
            revert ZoneBlocked(consumerZone);
        }
    }

    function requireRole(address party, TaqaRegistry.Role expected) external view {
        if (registry.roleOf(party) != expected) revert WrongRole(party, expected);
    }
}
