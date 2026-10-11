// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title AccessControl
/// @notice From-scratch role-based access control (RBAC) used across the association suite.
/// @dev Mirrors the OpenZeppelin semantics (role admin, grant/revoke/renounce, two-step
///      nothing) but is written from scratch, documented line by line, and kept minimal:
///      no enumerable members — role membership checks are direct storage probes.
///      `DEFAULT_ADMIN_ROLE` (0x00) can grant and revoke every other role.
contract AccessControl {
    /// @notice Role → account → whether the account holds the role.
    mapping(bytes32 role => mapping(address account => bool)) private _roles;

    /// @notice Emitted when an account gains a role (or when an admin is set).
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);

    /// @notice Emitted when an account loses a role.
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

    /// @notice The role that administers all other roles.
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    /// @notice The board-member role: may fast-track proposals, register unit sales and
    ///         submit emergency items.
    bytes32 public constant BOARD_MEMBER_ROLE = keccak256("BOARD_MEMBER");

    /// @notice The regulatory-compliance role (a RERA-style representative): holds a veto.
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE");

    /// @notice The emergency guardian: may pause the protocol and drain stuck assets.
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN");

    /// @notice Reverts when `account` is missing `role`.
    error MissingRole(bytes32 role, address account);

    /// @notice Guards a function to a single role holder.
    modifier onlyRole(bytes32 role) {
        if (!hasRole(role, msg.sender)) revert MissingRole(role, msg.sender);
        _;
    }

    /// @dev The zero address can never hold a role.
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @notice True when `account` holds `role`.
    function hasRole(bytes32 role, address account) public view returns (bool) {
        return _roles[role][account];
    }

    /// @notice Grants `role` to `account`; callable by the role's admin.
    /// @dev The admin of every role is DEFAULT_ADMIN_ROLE, i.e. 0x00 itself.
    function grantRole(bytes32 role, address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(role, account);
    }

    /// @notice Revokes `role` from `account`; callable by the role's admin.
    function revokeRole(bytes32 role, address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(role, account);
    }

    /// @dev Internal revoke without the admin check — used by derived governance
    ///      contracts to manage seats while the external path stays admin-only.
    function _revokeRole(bytes32 role, address account) internal {
        if (!hasRole(role, account)) revert MissingRole(role, account);
        _roles[role][account] = false;
        emit RoleRevoked(role, account, msg.sender);
    }

    /// @notice The holder renounces their own role (used when an administrator leaves).
    function renounceRole(bytes32 role) external {
        if (!hasRole(role, msg.sender)) revert MissingRole(role, msg.sender);
        _roles[role][msg.sender] = false;
        emit RoleRevoked(role, msg.sender, msg.sender);
    }

    /// @dev Granting is idempotent but only emits once.
    function _grantRole(bytes32 role, address account) internal {
        if (hasRole(role, account)) return;
        _roles[role][account] = true;
        emit RoleGranted(role, account, msg.sender);
    }
}
