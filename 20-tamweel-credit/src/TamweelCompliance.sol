// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";

/// @title TamweelCompliance
/// @notice The credit bureau of the bank: KYC tiers, credit scores (0–1000, set by
///         the credit committee) and per-score borrowing bands. The markets and the
///         loan book both consult these rules before extending credit.
contract TamweelCompliance is AccessControl {
    /// @notice The credit committee: sets scores and bands.
    bytes32 public constant COMMITTEE_ROLE = keccak256("COMMITTEE");

    /// @notice KYC tiers.
    enum KycTier { None, Standard, Accredited }

    /// @notice One borrower's credit profile.
    struct Profile {
        KycTier tier;
        uint16 creditScore; // 0–1000
        bool sanctioned;
        bool frozen;
    }

    mapping(address holder => Profile) public profiles;

    /// @notice Borrowing bands: minimum score → max borrow (in the payment stable).
    /// @dev A borrower needs the band for the requested amount.
    mapping(uint256 bandId => uint256 minScore) public bandMinScore;
    mapping(uint256 bandId => uint256 maxBorrow) public bandMaxBorrow;
    uint256 public bandCount;

    event KycSet(address indexed holder, KycTier tier);
    event ScoreSet(address indexed holder, uint16 score);
    event SanctionSet(address indexed holder, bool sanctioned);
    event HolderFrozen(address indexed holder, bool frozen);
    event BandSet(uint256 indexed bandId, uint256 minScore, uint256 maxBorrow);

    error ZeroAddress();
    error NotCommittee();
    error InvalidScore();
    error CreditDenied(address holder, uint16 score, uint256 needed);

    constructor(address[] memory committeeMembers) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(COMMITTEE_ROLE, msg.sender);
        for (uint256 i = 0; i < committeeMembers.length; i++) {
            if (committeeMembers[i] == address(0)) revert ZeroAddress();
            _grantRole(COMMITTEE_ROLE, committeeMembers[i]);
        }
        // default bands
        _setBand(600, 5_000 ether);
        _setBand(750, 25_000 ether);
        _setBand(900, 100_000 ether);
    }

    modifier onlyCommittee() {
        if (!hasRole(COMMITTEE_ROLE, msg.sender)) revert NotCommittee();
        _;
    }

    function _setBand(uint256 minScore, uint256 maxBorrow) internal {
        uint256 id = bandCount++;
        bandMinScore[id] = minScore;
        bandMaxBorrow[id] = maxBorrow;
        emit BandSet(id, minScore, maxBorrow);
    }

    function setBand(uint256 minScore, uint256 maxBorrow) external onlyCommittee {
        if (minScore > 1000 || maxBorrow == 0) revert InvalidScore();
        _setBand(minScore, maxBorrow);
    }

    /* ==================== CREDIT PROFILES ==================== */

    function setKyc(address holder, KycTier tier) external onlyCommittee {
        if (holder == address(0)) revert ZeroAddress();
        profiles[holder].tier = tier;
        emit KycSet(holder, tier);
    }

    function setCreditScore(address holder, uint16 score) external onlyCommittee {
        if (holder == address(0)) revert ZeroAddress();
        if (score > 1000) revert InvalidScore();
        profiles[holder].creditScore = score;
        emit ScoreSet(holder, score);
    }

    function setSanctioned(address holder, bool sanctioned_) external onlyCommittee {
        if (holder == address(0)) revert ZeroAddress();
        profiles[holder].sanctioned = sanctioned_;
        emit SanctionSet(holder, sanctioned_);
    }

    function setFrozen(address holder, bool frozen) external onlyCommittee {
        if (holder == address(0)) revert ZeroAddress();
        profiles[holder].frozen = frozen;
        emit HolderFrozen(holder, frozen);
    }

    /* ==================== QUERIES ==================== */

    function canTransact(address holder) public view returns (bool) {
        Profile storage p = profiles[holder];
        return !p.sanctioned && !p.frozen && p.tier != KycTier.None;
    }

    /// @notice The largest single exposure a holder may borrow.
    function maxBorrowFor(address holder) public view returns (uint256) {
        uint16 score = profiles[holder].creditScore;
        uint256 best = 0;
        for (uint256 i = 0; i < bandCount; i++) {
            if (score >= bandMinScore[i] && bandMaxBorrow[i] > best) best = bandMaxBorrow[i];
        }
        return best;
    }

    /// @notice Validates a loan request against the credit profile.
    function validateBorrow(address holder, uint256 amount) external view {
        if (!canTransact(holder)) revert();
        uint16 score = profiles[holder].creditScore;
        uint256 max = maxBorrowFor(holder);
        if (max < amount) revert CreditDenied(holder, score, max);
    }
}
