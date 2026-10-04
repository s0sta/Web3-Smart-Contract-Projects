// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {HuwiyyaRegistry} from "./HuwiyyaRegistry.sol";

/// @title HuwiyyaAttestations
/// @notice Trusted attestors (banks, employers, universities) submit signed
///         attestations about a DID — evidence hash, type, score and expiry —
///         and the reputation engine weights them.
contract HuwiyyaAttestations is AccessControl {
    /// @notice Attestors submit attestations.
    bytes32 public constant ATTESTOR_ROLE = keccak256("ATTESTOR");

    /// @notice One attestation.
    struct Attestation {
        address attestor;
        address subject;
        uint8 attType; // e.g. 1=KYC 2=academic 3=employment 4=residence
        uint16 score; // 0–1000 contribution to reputation
        uint64 expiresAt;
        bytes32 evidenceHash;
        bool revoked;
    }

    Attestation[] public attestations;
    mapping(address subject => uint256[]) public attestationsOf;

    /// @notice Per-attestor trust weights (bps of the score that counts).
    mapping(address attestor => uint256) public weightBps;
    mapping(uint8 attType => uint256) public typeWeightBps;

    HuwiyyaRegistry public immutable registry;

    event AttestationSubmitted(uint256 indexed attestationId, address indexed attestor, address indexed subject, uint8 attType, uint16 score);
    event AttestationRevoked(uint256 indexed attestationId);
    event WeightSet(address indexed attestor, uint256 bps);
    event TypeWeightSet(uint8 indexed attType, uint256 bps);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownAttestation(uint256 attestationId);
    error NotAttestor(uint256 attestationId);
    error AlreadyRevoked(uint256 attestationId);

    constructor(HuwiyyaRegistry registry_) {
        if (address(registry_) == address(0)) revert ZeroAddress();
        registry = registry_;
        typeWeightBps[1] = 4000; // KYC
        typeWeightBps[2] = 2500; // academic
        typeWeightBps[3] = 2000; // employment
        typeWeightBps[4] = 1500; // residence
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ATTESTOR_ROLE, msg.sender);
    }

    /* ==================== SUBMISSION ==================== */

    function submit(
        address subject,
        uint8 attType,
        uint16 score,
        uint64 expiresAt,
        bytes32 evidenceHash
    ) external onlyRole(ATTESTOR_ROLE) returns (uint256 attestationId) {
        if (subject == address(0)) revert ZeroAddress();
        if (score == 0 || score > 1000) revert ZeroAmount();
        if (!registry.isActive(subject)) revert();
        attestationId = attestations.length;
        attestations.push();
        Attestation storage a = attestations[attestationId];
        a.attestor = msg.sender;
        a.subject = subject;
        a.attType = attType;
        a.score = score;
        a.expiresAt = expiresAt;
        a.evidenceHash = evidenceHash;
        attestationsOf[subject].push(attestationId);
        emit AttestationSubmitted(attestationId, msg.sender, subject, attType, score);
    }

    function revoke(uint256 attestationId) external {
        Attestation storage a = attestations[attestationId];
        if (a.attestor == address(0)) revert UnknownAttestation(attestationId);
        if (msg.sender != a.attestor) revert NotAttestor(attestationId);
        if (a.revoked) revert AlreadyRevoked(attestationId);
        a.revoked = true;
        emit AttestationRevoked(attestationId);
    }

    /* ==================== WEIGHTS ==================== */

    function setWeight(address attestor, uint256 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (attestor == address(0)) revert ZeroAddress();
        if (bps > 10_000) revert ZeroAmount();
        weightBps[attestor] = bps;
        emit WeightSet(attestor, bps);
    }

    function setTypeWeight(uint8 attType, uint256 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > 10_000) revert ZeroAmount();
        typeWeightBps[attType] = bps;
        emit TypeWeightSet(attType, bps);
    }

    function attestationsOfList(address subject) external view returns (uint256[] memory) {
        return attestationsOf[subject];
    }

    function activeScore(uint256 attestationId) external view returns (uint256) {
        Attestation storage a = attestations[attestationId];
        if (a.attestor == address(0) || a.revoked) return 0;
        if (a.expiresAt != 0 && block.timestamp > a.expiresAt) return 0;
        return a.score;
    }
}
