// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {HuwiyyaRegistry} from "./HuwiyyaRegistry.sol";
import {HuwiyyaCredentials} from "./HuwiyyaCredentials.sol";
import {HuwiyyaReputation} from "./HuwiyyaReputation.sol";

/// @title HuwiyyaGates
/// @notice Service access gates: a policy bundles requirements — possession of
///         credentials from given schemas, a minimum reputation band, and a
///         disclosed-claim check (e.g. age ≥ 18) — and services query whether
///         a DID may pass.
contract HuwiyyaGates is AccessControl {
    /// @notice Services register policies.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR");

    /// @notice One policy.
    struct Policy {
        address service;
        uint256[] requiredSchemas; // must hold an active credential for each
        uint256 minReputation;
        uint256 requiredClaimIndex; // disclosed claim slot to inspect
        uint256 requiredClaimMin; // numeric minimum of that claim (0 = none)
        bool active;
    }

    Policy[] public policies;

    HuwiyyaRegistry public immutable registry;
    HuwiyyaCredentials public immutable credentials;
    HuwiyyaReputation public immutable reputation;

    event PolicyCreated(uint256 indexed policyId, address indexed service);
    event PolicySet(uint256 indexed policyId, bool active);
    event AccessChecked(uint256 indexed policyId, address indexed did, bool granted);

    error ZeroAddress();
    error UnknownPolicy(uint256 policyId);
    error InvalidPolicy();

    constructor(HuwiyyaRegistry registry_, HuwiyyaCredentials credentials_, HuwiyyaReputation reputation_) {
        if (address(registry_) == address(0) || address(credentials_) == address(0) || address(reputation_) == address(0)) {
            revert ZeroAddress();
        }
        registry = registry_;
        credentials = credentials_;
        reputation = reputation_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    /* ==================== POLICIES ==================== */

    function createPolicy(
        uint256[] calldata requiredSchemas,
        uint256 minReputation,
        uint256 requiredClaimIndex,
        uint256 requiredClaimMin
    ) external returns (uint256 policyId) {
        policyId = policies.length;
        policies.push();
        Policy storage p = policies[policyId];
        p.service = msg.sender;
        p.requiredSchemas = requiredSchemas;
        p.minReputation = minReputation;
        p.requiredClaimIndex = requiredClaimIndex;
        p.requiredClaimMin = requiredClaimMin;
        p.active = true;
        emit PolicyCreated(policyId, msg.sender);
    }

    function setActive(uint256 policyId, bool active) external {
        Policy storage p = policies[policyId];
        if (p.service == address(0)) revert UnknownPolicy(policyId);
        if (msg.sender != p.service && !hasRole(OPERATOR_ROLE, msg.sender)) revert();
        p.active = active;
        emit PolicySet(policyId, active);
    }

    /* ==================== ACCESS CHECKS ==================== */

    /// @notice Whether `did` currently satisfies the policy.
    function checkAccess(uint256 policyId, address did) public view returns (bool) {
        Policy storage p = policies[policyId];
        if (p.service == address(0)) revert UnknownPolicy(policyId);
        if (!p.active) return false;
        if (!registry.isActive(did)) return false;

        // 1) required credentials
        for (uint256 i = 0; i < p.requiredSchemas.length; i++) {
            if (!_holdsSchema(did, p.requiredSchemas[i])) return false;
        }
        // 2) reputation band
        if (p.minReputation > 0 && reputation.scoreOf(did) < p.minReputation) return false;
        return true;
    }

    /// @notice Full check including a disclosed numeric claim (holder supplies
    ///         the value; the service validates against the policy minimum).
    function checkAccessWithClaim(uint256 policyId, address did, uint256 disclosedValue) external returns (bool granted) {
        granted = checkAccess(policyId, did);
        if (granted) {
            Policy storage p = policies[policyId];
            if (p.requiredClaimMin > 0 && disclosedValue < p.requiredClaimMin) granted = false;
        }
        emit AccessChecked(policyId, did, granted);
    }

    function _holdsSchema(address did, uint256 schemaId) internal view returns (bool) {
        uint256[] memory ids = credentials.credentialsOfList(did);
        for (uint256 i = 0; i < ids.length; i++) {
            if (credentials.isValid(ids[i])) {
                ( , , uint256 s, , , , , ) = credentials.credentials(ids[i]);
                if (s == schemaId) return true;
            }
        }
        return false;
    }
}
