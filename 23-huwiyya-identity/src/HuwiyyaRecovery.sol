// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {HuwiyyaRegistry} from "./HuwiyyaRegistry.sol";

/// @title HuwiyyaRecovery
/// @notice Social recovery: a DID appoints 2-of-3 guardians; any guardian can
///         initiate a key rotation and the guardians approve it. The registry
///         performs the rotation on approval.
contract HuwiyyaRecovery is AccessControl {
    /// @notice The recovery role mirrors the registry's.
    bytes32 public constant RECOVERY_ROLE = keccak256("RECOVERY");

    /// @notice One pending recovery.
    struct Recovery {
        address did;
        address newKey;
        uint64 initiatedAt;
        mapping(address guardian => bool) approved;
        uint256 approvals;
        bool executed;
    }

    Recovery[] public recoveries;

    /// @notice Guardians per DID (max 8).
    mapping(address did => address[]) public guardiansOf;
    mapping(address did => mapping(address guardian => bool)) public isGuardian;
    mapping(address did => uint256) public guardianCount;

    uint256 public quorum;
    uint256 public recoveryDelay;

    HuwiyyaRegistry public immutable registry;

    event GuardiansSet(address indexed did, address[] guardians);
    event RecoveryInitiated(uint256 indexed recoveryId, address indexed did, address newKey);
    event RecoveryApproved(uint256 indexed recoveryId, address indexed guardian, uint256 approvals);
    event RecoveryExecuted(uint256 indexed recoveryId);

    error ZeroAddress();
    error UnknownRecovery(uint256 recoveryId);
    error NotGuardian(address guardian, address did);
    error AlreadyApproved(uint256 recoveryId, address guardian);
    error AlreadyExecuted(uint256 recoveryId);
    error DelayNotMet(uint256 recoveryId, uint256 readyAt);
    error TooManyGuardians();

    constructor(HuwiyyaRegistry registry_) {
        if (address(registry_) == address(0)) revert ZeroAddress();
        registry = registry_;
        quorum = 2;
        recoveryDelay = 1 days;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(RECOVERY_ROLE, msg.sender);
    }

    /* ==================== GUARDIANS ==================== */

    function setGuardians(address[] calldata guardians) external {
        if (guardians.length > 8) revert TooManyGuardians();
        // clear the previous set
        address[] storage current = guardiansOf[msg.sender];
        for (uint256 i = 0; i < current.length; i++) {
            isGuardian[msg.sender][current[i]] = false;
        }
        delete guardiansOf[msg.sender];
        guardianCount[msg.sender] = 0;
        for (uint256 i = 0; i < guardians.length; i++) {
            if (guardians[i] == address(0)) revert ZeroAddress();
            guardiansOf[msg.sender].push(guardians[i]);
            isGuardian[msg.sender][guardians[i]] = true;
        }
        guardianCount[msg.sender] = guardians.length;
        emit GuardiansSet(msg.sender, guardians);
    }

    /* ==================== RECOVERY FLOW ==================== */

    function initiate(address newKey) external returns (uint256 recoveryId) {
        if (newKey == address(0)) revert ZeroAddress();
        if (guardianCount[msg.sender] == 0) revert NotGuardian(address(0), msg.sender);
        recoveryId = recoveries.length;
        recoveries.push();
        Recovery storage r = recoveries[recoveryId];
        r.did = msg.sender;
        r.newKey = newKey;
        r.initiatedAt = uint64(block.timestamp);
        emit RecoveryInitiated(recoveryId, msg.sender, newKey);
    }

    function approve(uint256 recoveryId) external {
        Recovery storage r = recoveries[recoveryId];
        if (r.did == address(0)) revert UnknownRecovery(recoveryId);
        if (r.executed) revert AlreadyExecuted(recoveryId);
        if (!isGuardian[r.did][msg.sender]) revert NotGuardian(msg.sender, r.did);
        if (r.approved[msg.sender]) revert AlreadyApproved(recoveryId, msg.sender);
        r.approved[msg.sender] = true;
        r.approvals += 1;
        emit RecoveryApproved(recoveryId, msg.sender, r.approvals);
        if (r.approvals >= quorum) {
            _execute(recoveryId);
        }
    }

    function _execute(uint256 recoveryId) internal {
        Recovery storage r = recoveries[recoveryId];
        if (block.timestamp < r.initiatedAt + recoveryDelay) {
            revert DelayNotMet(recoveryId, r.initiatedAt + recoveryDelay);
        }
        r.executed = true;
        registry.recoveryRotate(r.did, r.newKey);
        emit RecoveryExecuted(recoveryId);
    }

    /* ==================== ADMIN ==================== */

    function setQuorum(uint256 q) external onlyRole(DEFAULT_ADMIN_ROLE) {
        quorum = q;
    }

    function setRecoveryDelay(uint256 delay_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        recoveryDelay = delay_;
    }
}
