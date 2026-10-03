// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {Checkpoints} from "./lib/Checkpoints.sol";

/// @title RERAPropertyRegistry
/// @notice The on-chain property ledger for fractional real-estate ownership — the Dubai
///         DLD/RERA tokenization pattern: every property is registered with an appraisal,
///         split into fractional shares, and only KYC-whitelisted investors may hold and
///         transfer them. Compliance can freeze a property; the property manager issues
///         shares and files re-appraisals.
///
/// @dev Share balances are checkpointed per block so downstream contracts (rental
///      distributions, governance) can compute entitlements at historical snapshots.
contract RERAPropertyRegistry is AccessControl {
    using Checkpoints for Checkpoints.Checkpoint[];

    /// @notice The RERA-licensed property manager: issues shares, files appraisals.
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER");

    /// @notice One registered property.
    struct Property {
        string name; // e.g. "Marina Gate Tower — Floor 21"
        uint256 totalShares; // total fractional shares (fixed at registration)
        uint256 issuedShares; // shares currently issued to investors
        uint256 valuationUsd; // latest appraisal, 18-decimal fixed point
        address manager; // the licensed property manager
        bool frozen; // compliance freeze: no transfers/issuance while true
        uint64 registeredAt;
    }

    /// @notice The property ledger.
    mapping(uint256 propertyId => Property) public properties;

    /// @notice Number of registered properties.
    uint256 public propertyCount;

    /// @notice Share balances per property per holder.
    mapping(uint256 propertyId => mapping(address holder => uint256)) public balanceOf;

    /// @notice KYC whitelist per property.
    mapping(uint256 propertyId => mapping(address investor => bool)) public whitelisted;

    /// @notice Snapshot history of each holder's share balance per property.
    mapping(uint256 propertyId => mapping(address holder => Checkpoints.Checkpoint[])) private _balanceHistory;

    event PropertyRegistered(uint256 indexed propertyId, string name, uint256 totalShares, uint256 valuationUsd);
    event SharesIssued(uint256 indexed propertyId, address indexed to, uint256 amount);
    event SharesTransferred(uint256 indexed propertyId, address indexed from, address indexed to, uint256 amount);
    event WhitelistSet(uint256 indexed propertyId, address indexed investor, bool allowed);
    event PropertyFrozen(uint256 indexed propertyId, bool frozen);
    event Appraised(uint256 indexed propertyId, uint256 oldValuation, uint256 newValuation);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownProperty(uint256 propertyId);
    error AlreadyRegistered();
    error NotWhitelisted(address investor);
    error Frozen(uint256 propertyId);
    error ExceedsSupply(uint256 requested, uint256 remaining);
    error InsufficientShares(uint256 balance, uint256 amount);
    error SameHolder(address holder);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);
        _grantRole(COMPLIANCE_ROLE, msg.sender);
    }

    /* ==================== REGISTRATION ==================== */

    /// @notice Registers a new property with its appraisal and total share count.
    /// @dev The manager files the DLD registration; shares are then issued over time.
    function registerProperty(
        string calldata name,
        uint256 totalShares,
        uint256 valuationUsd
    ) external onlyRole(MANAGER_ROLE) returns (uint256 propertyId) {
        if (totalShares == 0 || valuationUsd == 0) revert ZeroAmount();
        propertyId = propertyCount++;
        Property storage p = properties[propertyId];
        p.name = name;
        p.totalShares = totalShares;
        p.valuationUsd = valuationUsd;
        p.manager = msg.sender;
        p.registeredAt = uint64(block.timestamp);
        emit PropertyRegistered(propertyId, name, totalShares, valuationUsd);
    }

    /// @notice The manager files a re-appraisal (audited valuation updates).
    function appraise(uint256 propertyId, uint256 newValuation) external onlyRole(MANAGER_ROLE) {
        Property storage p = properties[propertyId];
        if (p.totalShares == 0) revert UnknownProperty(propertyId);
        if (newValuation == 0) revert ZeroAmount();
        emit Appraised(propertyId, p.valuationUsd, newValuation);
        p.valuationUsd = newValuation;
    }

    /* ==================== SHARE ISSUANCE & TRANSFER ==================== */

    /// @notice Issues shares to a KYC-whitelisted investor.
    function issueShares(uint256 propertyId, address to, uint256 amount) external onlyRole(MANAGER_ROLE) {
        Property storage p = properties[propertyId];
        if (p.totalShares == 0) revert UnknownProperty(propertyId);
        if (p.frozen) revert Frozen(propertyId);
        if (to == address(0)) revert ZeroAddress();
        if (!whitelisted[propertyId][to]) revert NotWhitelisted(to);
        if (amount == 0) revert ZeroAmount();
        if (p.issuedShares + amount > p.totalShares) revert ExceedsSupply(amount, p.totalShares - p.issuedShares);

        p.issuedShares += amount;
        _setBalance(propertyId, to, balanceOf[propertyId][to] + amount);
        emit SharesIssued(propertyId, to, amount);
    }

    /// @notice Transfers shares between two whitelisted holders.
    /// @dev Real-world accuracy: transfers are settlement-style — both parties must have
    ///      passed KYC and the property must not be frozen.
    function transferShares(uint256 propertyId, address to, uint256 amount) external {
        Property storage p = properties[propertyId];
        if (p.totalShares == 0) revert UnknownProperty(propertyId);
        if (p.frozen) revert Frozen(propertyId);
        if (to == address(0) || to == msg.sender) revert SameHolder(to);
        if (!whitelisted[propertyId][msg.sender] || !whitelisted[propertyId][to]) revert NotWhitelisted(to);

        uint256 bal = balanceOf[propertyId][msg.sender];
        if (bal < amount) revert InsufficientShares(bal, amount);

        _setBalance(propertyId, msg.sender, bal - amount);
        _setBalance(propertyId, to, balanceOf[propertyId][to] + amount);
        emit SharesTransferred(propertyId, msg.sender, to, amount);
    }

    /* ==================== COMPLIANCE ==================== */

    /// @notice The regulator sets/removes an investor's KYC status.
    function setWhitelisted(uint256 propertyId, address investor, bool allowed) external onlyRole(COMPLIANCE_ROLE) {
        if (properties[propertyId].totalShares == 0) revert UnknownProperty(propertyId);
        if (investor == address(0)) revert ZeroAddress();
        whitelisted[propertyId][investor] = allowed;
        emit WhitelistSet(propertyId, investor, allowed);
    }

    /// @notice The regulator freezes a property (no issuance/transfers while frozen).
    function setFrozen(uint256 propertyId, bool frozen) external onlyRole(COMPLIANCE_ROLE) {
        if (properties[propertyId].totalShares == 0) revert UnknownProperty(propertyId);
        properties[propertyId].frozen = frozen;
        emit PropertyFrozen(propertyId, frozen);
    }

    /* ==================== SNAPSHOTS ==================== */

    /// @notice A holder's share balance at or before `blockNumber` (distribution primitive).
    function getPastBalance(uint256 propertyId, address holder, uint256 blockNumber) external view returns (uint256) {
        return _balanceHistory[propertyId][holder].lookup(blockNumber);
    }

    function _setBalance(uint256 propertyId, address holder, uint256 newBalance) internal {
        balanceOf[propertyId][holder] = newBalance;
        _balanceHistory[propertyId][holder].write(balanceOf[propertyId][holder], newBalance);
    }
}
