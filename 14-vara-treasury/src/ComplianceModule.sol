// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";

/// @title ComplianceModule
/// @notice The VARA-style compliance layer for the regulated treasury: KYC tiers,
///         counterparty whitelisting, sanction screening and per-tier transaction
///         risk limits. Every rule change is an on-chain event — the audit trail
///         a regulator expects.
contract ComplianceModule is AccessControl {
    /// @notice The treasury reads rules from this module.
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY");

    /// @notice KYC tiers.
    enum KycTier { None, Standard, Enhanced }

    /// @notice Per-account compliance state.
    struct Account {
        KycTier tier;
        bool sanctioned; // OFAC-style list
        bool frozen;
    }

    /// @notice KYC state per account.
    mapping(address account => Account) public accounts;

    /// @notice Approved counterparties (banks, custodians, exchanges).
    mapping(address counterparty => bool) public counterparties;

    /// @notice Sanction list (blocked addresses).
    mapping(address blocked => bool) public sanctioned;

    /// @notice Risk limits per tier.
    mapping(KycTier tier => uint256) public tierDailyLimit; // per-day withdrawal ceiling
    mapping(KycTier tier => uint256) public tierSingleLimit; // per-transaction ceiling

    event KycSet(address indexed account, KycTier tier);
    event CounterpartySet(address indexed counterparty, bool approved);
    event SanctionSet(address indexed account, bool sanctioned);
    event AccountFrozen(address indexed account, bool frozen);
    event TierLimitSet(KycTier indexed tier, uint256 daily, uint256 single);

    error ZeroAddress();
    error InvalidTier();
    error NotCompliance();

    constructor(address[] memory complianceOfficers) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(COMPLIANCE_ROLE, msg.sender);
        for (uint256 i = 0; i < complianceOfficers.length; i++) {
            if (complianceOfficers[i] == address(0)) revert ZeroAddress();
            _grantRole(COMPLIANCE_ROLE, complianceOfficers[i]);
        }
        // default risk limits (AED-S, 18 decimals)
        tierDailyLimit[KycTier.Standard] = 50_000 ether;
        tierSingleLimit[KycTier.Standard] = 10_000 ether;
        tierDailyLimit[KycTier.Enhanced] = 500_000 ether;
        tierSingleLimit[KycTier.Enhanced] = 100_000 ether;
    }

    modifier onlyCompliance() {
        if (!hasRole(COMPLIANCE_ROLE, msg.sender)) revert NotCompliance();
        _;
    }

    /* ==================== KYC & SCREENING ==================== */

    function setKyc(address account, KycTier tier) external onlyCompliance {
        if (account == address(0)) revert ZeroAddress();
        accounts[account].tier = tier;
        emit KycSet(account, tier);
    }

    function setSanctioned(address account, bool sanctioned_) external onlyCompliance {
        if (account == address(0)) revert ZeroAddress();
        accounts[account].sanctioned = sanctioned_;
        sanctioned[account] = sanctioned_;
        emit SanctionSet(account, sanctioned_);
    }

    function setAccountFrozen(address account, bool frozen) external onlyCompliance {
        if (account == address(0)) revert ZeroAddress();
        accounts[account].frozen = frozen;
        emit AccountFrozen(account, frozen);
    }

    function setCounterparty(address counterparty, bool approved) external onlyCompliance {
        if (counterparty == address(0)) revert ZeroAddress();
        counterparties[counterparty] = approved;
        emit CounterpartySet(counterparty, approved);
    }

    /* ==================== RISK LIMITS ==================== */

    function setTierLimits(KycTier tier, uint256 dailyLimit, uint256 singleLimit) external onlyCompliance {
        if (uint8(tier) > uint8(KycTier.Enhanced)) revert InvalidTier();
        tierDailyLimit[tier] = dailyLimit;
        tierSingleLimit[tier] = singleLimit;
        emit TierLimitSet(tier, dailyLimit, singleLimit);
    }

    /* ==================== QUERIES ==================== */

    function isBlocked(address account) public view returns (bool) {
        Account storage a = accounts[account];
        return a.sanctioned || a.frozen;
    }

    function dailyLimitFor(address account) public view returns (uint256) {
        return tierDailyLimit[accounts[account].tier];
    }

    function singleLimitFor(address account) public view returns (uint256) {
        return tierSingleLimit[accounts[account].tier];
    }
}
