// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";

/// @title RahalaCompliance
/// @notice The network's rulebook: KYC tiers with per-tier transfer limits,
///         sanctions, a travel-rule memo and region allowlists. Every payment,
///         conversion and invoice consults these gates.
contract RahalaCompliance is AccessControl {
    /// @notice Compliance officers manage profiles and limits.
    bytes32 public constant OFFICER_ROLE = keccak256("OFFICER");

    /// @notice KYC tiers.
    enum KycTier { None, Standard, Verified }

    /// @notice One participant's profile.
    struct Profile {
        KycTier tier;
        bool sanctioned;
        bool frozen;
        uint64 homeRegion;
    }

    mapping(address participant => Profile) public profiles;

    /// @notice Per-tier single-transfer caps (in the settlement stable).
    mapping(KycTier tier => uint256) public transferCap;

    /// @notice Per-tier rolling 24h volume caps.
    mapping(KycTier tier => uint256) public dailyCap;
    mapping(address participant => uint256) public dailyUsed;
    mapping(address participant => uint256) public lastWindow;

    /// @notice Regions allowed to participate (by numeric code).
    mapping(uint64 region => bool) public regionAllowed;

    bool public paused;

    event KycSet(address indexed participant, KycTier tier);
    event SanctionSet(address indexed participant, bool sanctioned);
    event ParticipantFrozen(address indexed participant, bool frozen);
    event RegionSet(uint64 indexed region, bool allowed);
    event CapsSet(KycTier indexed tier, uint256 transferCap, uint256 dailyCap);
    event Paused(bool paused);

    error ZeroAddress();
    error NotOfficer();
    error TransferLimit(uint256 amount, uint256 cap);
    error DailyLimit(uint256 used, uint256 cap);
    error ParticipantBlocked(address participant);
    error RegionBlocked(uint64 region);
    error NetworkPaused();

    constructor(address[] memory officers) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OFFICER_ROLE, msg.sender);
        for (uint256 i = 0; i < officers.length; i++) {
            if (officers[i] == address(0)) revert ZeroAddress();
            _grantRole(OFFICER_ROLE, officers[i]);
        }
        transferCap[KycTier.Standard] = 10_000 ether;
        transferCap[KycTier.Verified] = 250_000 ether;
        dailyCap[KycTier.Standard] = 50_000 ether;
        dailyCap[KycTier.Verified] = 1_000_000 ether;
    }

    modifier onlyOfficer() {
        if (!hasRole(OFFICER_ROLE, msg.sender)) revert NotOfficer();
        _;
    }

    /* ==================== PROFILES ==================== */

    function setKyc(address participant, KycTier tier) external onlyOfficer {
        if (participant == address(0)) revert ZeroAddress();
        profiles[participant].tier = tier;
        emit KycSet(participant, tier);
    }

    function setSanctioned(address participant, bool sanctioned_) external onlyOfficer {
        if (participant == address(0)) revert ZeroAddress();
        profiles[participant].sanctioned = sanctioned_;
        emit SanctionSet(participant, sanctioned_);
    }

    function setFrozen(address participant, bool frozen) external onlyOfficer {
        if (participant == address(0)) revert ZeroAddress();
        profiles[participant].frozen = frozen;
        emit ParticipantFrozen(participant, frozen);
    }

    function setHomeRegion(address participant, uint64 region) external onlyOfficer {
        profiles[participant].homeRegion = region;
    }

    function setRegionAllowed(uint64 region, bool allowed) external onlyOfficer {
        regionAllowed[region] = allowed;
        emit RegionSet(region, allowed);
    }

    function setCaps(KycTier tier, uint256 transferCap_, uint256 dailyCap_) external onlyOfficer {
        transferCap[tier] = transferCap_;
        dailyCap[tier] = dailyCap_;
        emit CapsSet(tier, transferCap_, dailyCap_);
    }

    function setPaused(bool paused_) external onlyOfficer {
        paused = paused_;
        emit Paused(paused_);
    }

    /* ==================== GATES ==================== */

    function canTransact(address participant) public view returns (bool) {
        Profile storage p = profiles[participant];
        return !paused && !p.sanctioned && !p.frozen && p.tier != KycTier.None;
    }

    /// @notice Validates a transfer: KYC, sanctions, region, caps, daily volume.
    function validateTransfer(
        address sender,
        address recipient,
        uint64 recipientRegion,
        uint256 amount,
        bytes32 travelRuleMemo
    ) external {
        if (paused) revert NetworkPaused();
        if (!canTransact(sender)) revert ParticipantBlocked(sender);
        if (!canTransact(recipient)) revert ParticipantBlocked(recipient);
        if (!regionAllowed[recipientRegion]) revert RegionBlocked(recipientRegion);
        uint256 cap = transferCap[profiles[sender].tier];
        if (amount > cap) revert TransferLimit(amount, cap);

        uint256 window = block.timestamp / 1 days;
        if (lastWindow[sender] != window) {
            lastWindow[sender] = window;
            dailyUsed[sender] = 0;
        }
        uint256 used = dailyUsed[sender] + amount;
        uint256 daily = dailyCap[profiles[sender].tier];
        if (used > daily) revert DailyLimit(used, daily);
        dailyUsed[sender] = used;

        // the travel-rule memo must be present for Verified tier flows
        if (profiles[sender].tier == KycTier.Verified && travelRuleMemo == bytes32(0)) revert();
        travelRuleMemo; // recorded by the caller
    }
}
