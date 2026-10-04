// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";

/// @title HuwiyyaRegistry
/// @notice The DID ledger: every address controls a DID record with a primary
///         key, delegated keys and a document hash. Keys can be rotated (the
///         recovery module does this for guardians), DIDs can be frozen by
///         compliance and revoked entirely.
contract HuwiyyaRegistry is AccessControl {
    /// @notice Compliance can freeze DIDs.
    bytes32 public constant OFFICER_ROLE = keccak256("OFFICER");

    /// @notice The recovery module rotates keys on guardian approval.
    bytes32 public constant RECOVERY_ROLE = keccak256("RECOVERY");

    /// @notice One DID record.
    struct Did {
        address primaryKey;
        bytes32 docHash;
        uint64 created;
        uint64 lastRotated;
        bool frozen;
        bool revoked;
    }

    mapping(address did => Did) public dids;
    mapping(address did => mapping(address key => bool)) public delegated;

    uint256 public didCount;

    event DidCreated(address indexed did, address indexed primaryKey, bytes32 docHash);
    event KeyRotated(address indexed did, address oldKey, address newKey);
    event DocUpdated(address indexed did, bytes32 docHash);
    event DelegationSet(address indexed did, address indexed key, bool delegated);
    event DidFrozen(address indexed did, bool frozen);
    event DidRevoked(address indexed did);

    error ZeroAddress();
    error UnknownDid(address did);
    error Unauthorized(address did, address caller);
    error DidRevokedError(address did);
    error DidFrozenError(address did);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OFFICER_ROLE, msg.sender);
        _grantRole(RECOVERY_ROLE, msg.sender);
    }

    modifier activeDid(address did) {
        if (dids[did].primaryKey == address(0)) revert UnknownDid(did);
        if (dids[did].revoked) revert DidRevokedError(did);
        if (dids[did].frozen) revert DidFrozenError(did);
        _;
    }

    modifier onlyController(address did) {
        if (msg.sender != dids[did].primaryKey && !delegated[did][msg.sender]) revert Unauthorized(did, msg.sender);
        _;
    }

    /* ==================== DID LIFECYCLE ==================== */

    function createDid(bytes32 docHash) external returns (address did) {
        did = msg.sender;
        if (dids[did].primaryKey != address(0)) revert UnknownDid(did);
        dids[did] = Did({
            primaryKey: msg.sender,
            docHash: docHash,
            created: uint64(block.timestamp),
            lastRotated: uint64(block.timestamp),
            frozen: false,
            revoked: false
        });
        didCount += 1;
        emit DidCreated(did, msg.sender, docHash);
    }

    function updateDoc(bytes32 docHash) external activeDid(msg.sender) onlyController(msg.sender) {
        dids[msg.sender].docHash = docHash;
        emit DocUpdated(msg.sender, docHash);
    }

    function rotateKey(address newKey) external activeDid(msg.sender) onlyController(msg.sender) {
        if (newKey == address(0)) revert ZeroAddress();
        address old = dids[msg.sender].primaryKey;
        dids[msg.sender].primaryKey = newKey;
        dids[msg.sender].lastRotated = uint64(block.timestamp);
        emit KeyRotated(msg.sender, old, newKey);
    }

    function setDelegation(address key, bool allowed) external activeDid(msg.sender) onlyController(msg.sender) {
        if (key == address(0)) revert ZeroAddress();
        delegated[msg.sender][key] = allowed;
        emit DelegationSet(msg.sender, key, allowed);
    }

    function revokeDid(address did) external activeDid(did) onlyController(did) {
        dids[did].revoked = true;
        emit DidRevoked(did);
    }

    /* ==================== RECOVERY & COMPLIANCE ==================== */

    /// @notice The recovery module rotates the primary key after guardian approval.
    function recoveryRotate(address did, address newKey) external onlyRole(RECOVERY_ROLE) {
        if (dids[did].primaryKey == address(0)) revert UnknownDid(did);
        if (newKey == address(0)) revert ZeroAddress();
        address old = dids[did].primaryKey;
        dids[did].primaryKey = newKey;
        dids[did].lastRotated = uint64(block.timestamp);
        emit KeyRotated(did, old, newKey);
    }

    function setFrozen(address did, bool frozen) external onlyRole(OFFICER_ROLE) {
        if (dids[did].primaryKey == address(0)) revert UnknownDid(did);
        dids[did].frozen = frozen;
        emit DidFrozen(did, frozen);
    }

    function isActive(address did) external view returns (bool) {
        Did storage d = dids[did];
        return d.primaryKey != address(0) && !d.revoked && !d.frozen;
    }
}
