// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";

/// @title SahmCompliance
/// @notice The trading desk's rulebook: KYC tiers with per-tier daily volume limits,
///         sanction screening and a global trading halt switch. Every order, swap and
///         position consults these rules.
contract SahmCompliance is AccessControl {
    /// @notice Compliance officers manage KYC and limits.
    bytes32 public constant OFFICER_ROLE = keccak256("OFFICER");

    /// @notice KYC tiers.
    enum KycTier { None, Retail, Professional }

    /// @notice Per-trader state.
    struct Trader {
        KycTier tier;
        bool sanctioned;
        bool frozen;
    }

    mapping(address trader => Trader) public traders;

    /// @notice Per-tier daily volume caps (in the quote stable).
    mapping(KycTier tier => uint256) public dailyVolumeCap;

    /// @notice Daily volume used per trader (rolling 24h window).
    mapping(address trader => uint256) public dailyVolumeUsed;
    mapping(address trader => uint256) public lastVolumeWindow;

    /// @notice A global trading halt (circuit breaker).
    bool public tradingHalted;

    event KycSet(address indexed trader, KycTier tier);
    event SanctionSet(address indexed trader, bool sanctioned);
    event TraderFrozen(address indexed trader, bool frozen);
    event VolumeCapSet(KycTier indexed tier, uint256 cap);
    event TradingHalted(bool halted);

    error ZeroAddress();
    error NotCompliance();
    error VolumeLimit(uint256 used, uint256 cap);
    error TradingBlocked();
    error TraderBlocked(address trader);

    constructor(address[] memory officers) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OFFICER_ROLE, msg.sender);
        for (uint256 i = 0; i < officers.length; i++) {
            if (officers[i] == address(0)) revert ZeroAddress();
            _grantRole(OFFICER_ROLE, officers[i]);
        }
        dailyVolumeCap[KycTier.Retail] = 25_000 ether;
        dailyVolumeCap[KycTier.Professional] = 250_000 ether;
    }

    modifier onlyCompliance() {
        if (!hasRole(OFFICER_ROLE, msg.sender)) revert NotCompliance();
        _;
    }

    /* ==================== KYC & SCREENING ==================== */

    function setKyc(address trader, KycTier tier) external onlyCompliance {
        if (trader == address(0)) revert ZeroAddress();
        traders[trader].tier = tier;
        emit KycSet(trader, tier);
    }

    function setSanctioned(address trader, bool sanctioned_) external onlyCompliance {
        if (trader == address(0)) revert ZeroAddress();
        traders[trader].sanctioned = sanctioned_;
        emit SanctionSet(trader, sanctioned_);
    }

    function setFrozen(address trader, bool frozen) external onlyCompliance {
        if (trader == address(0)) revert ZeroAddress();
        traders[trader].frozen = frozen;
        emit TraderFrozen(trader, frozen);
    }

    function setVolumeCap(KycTier tier, uint256 cap) external onlyCompliance {
        dailyVolumeCap[tier] = cap;
        emit VolumeCapSet(tier, cap);
    }

    /* ==================== TRADING GATES ==================== */

    function setTradingHalted(bool halted) external onlyCompliance {
        tradingHalted = halted;
        emit TradingHalted(halted);
    }

    function canTrade(address trader) public view returns (bool) {
        Trader storage t = traders[trader];
        return !tradingHalted && !t.sanctioned && !t.frozen && t.tier != KycTier.None;
    }

    /// @notice Records traded volume and enforces the daily cap (rolling 24h).
    function recordVolume(address trader, uint256 amount) external {
        if (amount == 0) return;
        if (!canTrade(trader)) revert TraderBlocked(trader);
        uint256 window = block.timestamp / 1 days;
        if (lastVolumeWindow[trader] != window) {
            lastVolumeWindow[trader] = window;
            dailyVolumeUsed[trader] = 0;
        }
        uint256 used = dailyVolumeUsed[trader] + amount;
        uint256 cap = dailyVolumeCap[traders[trader].tier];
        if (used > cap) revert VolumeLimit(used, cap);
        dailyVolumeUsed[trader] = used;
    }
}
