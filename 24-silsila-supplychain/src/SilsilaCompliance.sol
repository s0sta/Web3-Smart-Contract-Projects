// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {SilsilaRegistry} from "./SilsilaRegistry.sol";

/// @title SilsilaCompliance
/// @notice Trade compliance: export-control route validation, sanction
///         screening on both parties, and mandatory document hashes for
///         cross-border legs.
contract SilsilaCompliance is AccessControl {
    /// @notice Compliance officers manage routes.
    bytes32 public constant OFFICER_ROLE = keccak256("OFFICER");

    /// @notice Regions trade may flow through.
    mapping(uint64 region => bool) public regionAllowed;

    /// @notice Document hashes required on cross-border legs.
    bool public requireExportDocs;

    SilsilaRegistry public immutable registry;

    event RegionSet(uint64 indexed region, bool allowed);
    event ExportDocsSet(bool required);

    error ZeroAddress();
    error NotOfficer();
    error InactiveParty(address party);
    error RegionBlocked(uint64 region);
    error MissingExportDocs();
    error WrongRole(address party, SilsilaRegistry.Role expected);

    constructor(SilsilaRegistry registry_) {
        if (address(registry_) == address(0)) revert ZeroAddress();
        registry = registry_;
        requireExportDocs = true;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OFFICER_ROLE, msg.sender);
    }

    modifier onlyOfficer() {
        if (!hasRole(OFFICER_ROLE, msg.sender)) revert NotOfficer();
        _;
    }

    function setRegionAllowed(uint64 region, bool allowed) external onlyOfficer {
        regionAllowed[region] = allowed;
        emit RegionSet(region, allowed);
    }

    function setRequireExportDocs(bool required) external onlyOfficer {
        requireExportDocs = required;
        emit ExportDocsSet(required);
    }

    /* ==================== VALIDATION ==================== */

    function validateParties(address a, address b) external view {
        if (!registry.isActive(a)) revert InactiveParty(a);
        if (!registry.isActive(b)) revert InactiveParty(b);
    }

    /// @notice Validates a trade leg between two regions.
    function validateRoute(
        address from,
        address to,
        uint64 destinationRegion,
        bool crossBorder,
        bytes32 docsHash
    ) external view {
        if (!registry.isActive(from)) revert InactiveParty(from);
        if (!registry.isActive(to)) revert InactiveParty(to);
        if (!regionAllowed[destinationRegion]) revert RegionBlocked(destinationRegion);
        if (crossBorder && requireExportDocs && docsHash == bytes32(0)) revert MissingExportDocs();
    }

    function requireRole(address party, SilsilaRegistry.Role expected) external view {
        if (registry.roleOf(party) != expected) revert WrongRole(party, expected);
    }
}
