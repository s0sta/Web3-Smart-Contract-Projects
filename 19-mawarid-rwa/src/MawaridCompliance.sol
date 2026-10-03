// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";

/// @title MawaridCompliance
/// @notice The regulatory layer of the platform: KYC tiers, sanction screening,
///         accredited-investor flags and per-asset exposure limits. Every transfer
///         on the share token and every market order passes through these rules.
contract MawaridCompliance is AccessControl {
    /// @notice KYC tiers.
    enum KycTier { None, Standard, Accredited }

    /// @notice Per-holder compliance state.
    struct Holder {
        KycTier tier;
        bool sanctioned;
        bool frozen;
    }

    mapping(address holder => Holder) public holders;

    /// @notice Per-asset exposure limits (max shares a single holder may own).
    mapping(uint256 assetId => uint256) public maxExposure;

    /// @notice Per-asset minimum investment (shares).
    mapping(uint256 assetId => uint256) public minInvestment;

    event KycSet(address indexed holder, KycTier tier);
    event SanctionSet(address indexed holder, bool sanctioned);
    event HolderFrozen(address indexed holder, bool frozen);
    event ExposureSet(uint256 indexed assetId, uint256 maxShares);
    event MinInvestmentSet(uint256 indexed assetId, uint256 minShares);

    error ZeroAddress();
    error NotCompliance();
    error ExceedsExposure(uint256 assetId, uint256 held, uint256 max);

    constructor(address[] memory officers) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(COMPLIANCE_ROLE, msg.sender);
        for (uint256 i = 0; i < officers.length; i++) {
            if (officers[i] == address(0)) revert ZeroAddress();
            _grantRole(COMPLIANCE_ROLE, officers[i]);
        }
    }

    modifier onlyCompliance() {
        if (!hasRole(COMPLIANCE_ROLE, msg.sender)) revert NotCompliance();
        _;
    }

    /* ==================== KYC & SCREENING ==================== */

    function setKyc(address holder, KycTier tier) external onlyCompliance {
        if (holder == address(0)) revert ZeroAddress();
        holders[holder].tier = tier;
        emit KycSet(holder, tier);
    }

    function setSanctioned(address holder, bool sanctioned_) external onlyCompliance {
        if (holder == address(0)) revert ZeroAddress();
        holders[holder].sanctioned = sanctioned_;
        emit SanctionSet(holder, sanctioned_);
    }

    function setFrozen(address holder, bool frozen) external onlyCompliance {
        if (holder == address(0)) revert ZeroAddress();
        holders[holder].frozen = frozen;
        emit HolderFrozen(holder, frozen);
    }

    /* ==================== LIMITS ==================== */

    function setExposureLimit(uint256 assetId, uint256 maxShares) external onlyCompliance {
        maxExposure[assetId] = maxShares;
        emit ExposureSet(assetId, maxShares);
    }

    function setMinInvestment(uint256 assetId, uint256 minShares) external onlyCompliance {
        minInvestment[assetId] = minShares;
        emit MinInvestmentSet(assetId, minShares);
    }

    /* ==================== QUERIES ==================== */

    /// @notice Whether a holder may receive shares of the given asset.
    function canHold(uint256 assetId, address holder) public view returns (bool) {
        Holder storage h = holders[holder];
        return !h.sanctioned && !h.frozen && h.tier != KycTier.None;
    }

    /// @notice Validates an incoming transfer against exposure caps.
    function validateReceipt(uint256 assetId, address holder, uint256 currentBalance, uint256 amount) external view {
        if (!canHold(assetId, holder)) revert();
        uint256 max = maxExposure[assetId];
        if (max > 0 && currentBalance + amount > max) revert ExceedsExposure(assetId, currentBalance, max);
    }
}
