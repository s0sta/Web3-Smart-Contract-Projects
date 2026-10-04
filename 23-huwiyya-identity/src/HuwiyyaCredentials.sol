// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {HuwiyyaRegistry} from "./HuwiyyaRegistry.sol";
import {HuwiyyaSchema} from "./HuwiyyaSchema.sol";
import {HuwiyyaTreasury} from "./HuwiyyaTreasury.sol";
import {HuwiyyaMerkle} from "./HuwiyyaMerkle.sol";
import {IERC20} from "./interfaces/IERC20.sol";

/// @title HuwiyyaCredentials
/// @notice The verifiable-credential ledger: registered issuers issue credentials
///         (schema + claims Merkle root + expiry) to DIDs, holders present them
///         with selective-disclosure proofs, and issuers revoke them.
contract HuwiyyaCredentials is AccessControl {
    /// @notice Credential issuers (trusted organizations).
    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER");

    /// @notice One credential.
    struct Credential {
        address issuer;
        address subject;
        uint256 schemaId;
        bytes32 claimsRoot; // Merkle root of the hashed claims
        uint64 issuedAt;
        uint64 expiresAt;
        bool revocable;
        bool revoked;
    }

    Credential[] public credentials;
    mapping(address subject => uint256[]) public credentialsOf;

    uint256 public issuanceFee;

    HuwiyyaRegistry public immutable registry;
    HuwiyyaSchema public immutable schemas;
    HuwiyyaTreasury public immutable treasury;
    IERC20 public immutable feeToken;

    event CredentialIssued(uint256 indexed credentialId, address indexed issuer, address indexed subject, uint256 schemaId);
    event CredentialRevoked(uint256 indexed credentialId);
    event CredentialPresented(uint256 indexed credentialId, address indexed verifier);
    event FeeSet(uint256 fee);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownCredential(uint256 credentialId);
    error NotIssuerOrSubject(uint256 credentialId);
    error AlreadyRevoked(uint256 credentialId);
    error CredentialExpired(uint256 credentialId);
    error TransferFailed();

    constructor(
        HuwiyyaRegistry registry_,
        HuwiyyaSchema schemas_,
        HuwiyyaTreasury treasury_,
        IERC20 feeToken_
    ) {
        if (address(registry_) == address(0) || address(schemas_) == address(0) || address(treasury_) == address(0) || address(feeToken_) == address(0)) {
            revert ZeroAddress();
        }
        registry = registry_;
        schemas = schemas_;
        treasury = treasury_;
        feeToken = feeToken_;
        issuanceFee = 5 ether;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ISSUER_ROLE, msg.sender);
    }

    /* ==================== ISSUANCE ==================== */

    function issue(
        address subject,
        uint256 schemaId,
        bytes32 claimsRoot,
        uint64 expiresAt,
        bool revocable
    ) external onlyRole(ISSUER_ROLE) returns (uint256 credentialId) {
        if (subject == address(0)) revert ZeroAddress();
        if (!schemas.isActive(schemaId)) revert ZeroAmount();
        if (!registry.isActive(subject)) revert();
        if (expiresAt != 0 && expiresAt <= block.timestamp) revert CredentialExpired(0);

        if (issuanceFee > 0) {
            if (!feeToken.transferFrom(msg.sender, address(this), issuanceFee)) revert TransferFailed();
            if (!feeToken.approve(address(treasury), issuanceFee)) revert TransferFailed();
            treasury.receiveFees(issuanceFee);
        }

        credentialId = credentials.length;
        credentials.push();
        Credential storage c = credentials[credentialId];
        c.issuer = msg.sender;
        c.subject = subject;
        c.schemaId = schemaId;
        c.claimsRoot = claimsRoot;
        c.issuedAt = uint64(block.timestamp);
        c.expiresAt = expiresAt;
        c.revocable = revocable;
        credentialsOf[subject].push(credentialId);
        emit CredentialIssued(credentialId, msg.sender, subject, schemaId);
    }

    /* ==================== REVOCATION ==================== */

    function revoke(uint256 credentialId) external {
        Credential storage c = credentials[credentialId];
        if (c.issuer == address(0)) revert UnknownCredential(credentialId);
        if (msg.sender != c.issuer && msg.sender != c.subject) revert NotIssuerOrSubject(credentialId);
        if (!c.revocable) revert AlreadyRevoked(credentialId);
        if (c.revoked) revert AlreadyRevoked(credentialId);
        c.revoked = true;
        emit CredentialRevoked(credentialId);
    }

    /* ==================== PRESENTATION ==================== */

    /// @notice A holder presents a credential to a verifier with a selective
    ///         disclosure: one claim leaf plus its Merkle proof.
    function present(
        uint256 credentialId,
        address verifier,
        uint256 claimIndex,
        bytes32 claimLeaf,
        bytes32[] calldata proof
    ) external returns (bool) {
        Credential storage c = credentials[credentialId];
        if (c.issuer == address(0)) revert UnknownCredential(credentialId);
        if (msg.sender != c.subject) revert NotIssuerOrSubject(credentialId);
        if (c.revoked) revert AlreadyRevoked(credentialId);
        if (c.expiresAt != 0 && block.timestamp > c.expiresAt) revert CredentialExpired(credentialId);

        bool valid = HuwiyyaMerkle.verify(c.claimsRoot, claimLeaf, claimIndex, proof);
        emit CredentialPresented(credentialId, verifier);
        return valid;
    }

    /// @notice Verifier-side check: is the credential valid right now?
    function credentialsOfList(address subject) external view returns (uint256[] memory) {
        return credentialsOf[subject];
    }

    function isValid(uint256 credentialId) external view returns (bool) {
        Credential storage c = credentials[credentialId];
        if (c.issuer == address(0) || c.revoked) return false;
        if (c.expiresAt != 0 && block.timestamp > c.expiresAt) return false;
        if (!registry.isActive(c.subject)) return false;
        return true;
    }

    function setIssuanceFee(uint256 fee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        issuanceFee = fee;
        emit FeeSet(fee);
    }
}

