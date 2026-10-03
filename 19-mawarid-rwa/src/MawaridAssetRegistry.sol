// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";

/// @title MawaridAssetRegistry
/// @notice The on-chain ledger of tokenized real-world assets (properties). Every
///         asset carries its documentation hash, appraisal history, share supply
///         and lifecycle status. Only the platform manager registers and appraises;
///         compliance freezes; the governor liquidates.
contract MawaridAssetRegistry is AccessControl {
    /// @notice The platform manager (RERA-licensed operator): registers, appraises.
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER");

    /// @notice Asset lifecycle.
    enum Status { Draft, Live, Frozen, Liquidated }

    /// @notice One tokenized asset.
    struct Asset {
        string name; // e.g. "Marina Gate Tower — Floor 21"
        string assetClass; // "Residential", "Commercial", "Industrial", "Mixed-use"
        bytes32 documentationHash; // title deed + valuation + inspection bundle
        uint256 totalShares; // fixed supply
        uint256 issuedShares;
        uint256 appraisalUsd; // latest appraisal (18-decimals)
        uint64 registeredAt;
        Status status;
    }

    /// @notice The asset ledger.
    mapping(uint256 assetId => Asset) public assets;

    /// @notice Appraisal history per asset.
    mapping(uint256 assetId => uint256[]) public appraisalHistory;

    /// @notice Number of registered assets.
    uint256 public assetCount;

    event AssetRegistered(uint256 indexed assetId, string name, string assetClass, uint256 totalShares, uint256 appraisalUsd);
    event Appraised(uint256 indexed assetId, uint256 oldAppraisal, uint256 newAppraisal);
    event AssetStatusSet(uint256 indexed assetId, Status status);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownAsset(uint256 assetId);
    error InvalidStatus(Status current, Status next);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);
    }

    /* ==================== REGISTRATION & APPRAISALS ==================== */

    /// @notice Registers a new tokenized asset.
    function registerAsset(
        string calldata name,
        string calldata assetClass,
        bytes32 documentationHash,
        uint256 totalShares,
        uint256 appraisalUsd
    ) external onlyRole(MANAGER_ROLE) returns (uint256 assetId) {
        if (totalShares == 0 || appraisalUsd == 0) revert ZeroAmount();
        if (documentationHash == bytes32(0)) revert ZeroAmount();
        assetId = assetCount++;
        assets[assetId] = Asset({
            name: name,
            assetClass: assetClass,
            documentationHash: documentationHash,
            totalShares: totalShares,
            issuedShares: 0,
            appraisalUsd: appraisalUsd,
            registeredAt: uint64(block.timestamp),
            status: Status.Draft
        });
        appraisalHistory[assetId].push(appraisalUsd);
        emit AssetRegistered(assetId, name, assetClass, totalShares, appraisalUsd);
    }

    /// @notice Files a re-appraisal (audited valuation).
    function appraise(uint256 assetId, uint256 newAppraisal) external onlyRole(MANAGER_ROLE) {
        Asset storage a = assets[assetId];
        if (a.totalShares == 0) revert UnknownAsset(assetId);
        if (newAppraisal == 0) revert ZeroAmount();
        emit Appraised(assetId, a.appraisalUsd, newAppraisal);
        a.appraisalUsd = newAppraisal;
        appraisalHistory[assetId].push(newAppraisal);
    }

    /// @notice Records issued shares when the primary market mints them.
    function recordIssuance(uint256 assetId, uint256 amount) external {
        // callable by the primary market contract (granted MANAGER_ROLE at wiring)
        if (!hasRole(MANAGER_ROLE, msg.sender)) revert();
        Asset storage a = assets[assetId];
        if (a.totalShares == 0) revert UnknownAsset(assetId);
        if (a.issuedShares + amount > a.totalShares) revert ZeroAmount();
        a.issuedShares += amount;
    }

    /* ==================== LIFECYCLE ==================== */

    /// @notice The manager moves the asset through its lifecycle.
    ///         Draft → Live → Frozen → Liquidated (and Frozen → Live).
    function setStatus(uint256 assetId, Status next) external onlyRole(MANAGER_ROLE) {
        Asset storage a = assets[assetId];
        if (a.totalShares == 0) revert UnknownAsset(assetId);
        Status current = a.status;
        bool valid =
            (current == Status.Draft && next == Status.Live) ||
            (current == Status.Live && (next == Status.Frozen || next == Status.Liquidated)) ||
            (current == Status.Frozen && (next == Status.Live || next == Status.Liquidated));
        if (!valid) revert InvalidStatus(current, next);
        a.status = next;
        emit AssetStatusSet(assetId, next);
    }
}
