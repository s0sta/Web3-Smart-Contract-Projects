// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";

/// @title AtaaRegistry
/// @notice The platform directory: donors, KYC'd beneficiaries and the zakat
///         committee. Beneficiaries carry a needs profile; donors are simply
///         active accounts.
contract AtaaRegistry is AccessControl {
    /// @notice Compliance officers manage beneficiaries.
    bytes32 public constant OFFICER_ROLE = keccak256("OFFICER");

    /// @notice The zakat committee proposes and approves allocations.
    bytes32 public constant COMMITTEE_ROLE = keccak256("COMMITTEE");

    /// @notice Beneficiary categories.
    enum Category { None, Orphans, Families, Education, Medical, Food, Water, Emergency }

    /// @notice One beneficiary profile.
    struct Beneficiary {
        bytes32 nameHash; // privacy-preserving identity
        Category category;
        uint256 monthlyNeed; // needed per month
        string purpose;
        bool verified;
        bool active;
    }

    Beneficiary[] public beneficiaries;
    mapping(address donor => bool) public isDonor;

    uint256 public beneficiaryCount;

    event DonorRegistered(address indexed donor);
    event BeneficiaryRegistered(uint256 indexed beneficiaryId, Category category, uint256 monthlyNeed);
    event BeneficiaryUpdated(uint256 indexed beneficiaryId);
    event BeneficiaryDeactivated(uint256 indexed beneficiaryId);

    error ZeroAddress();
    error NotOfficer();
    error UnknownBeneficiary(uint256 beneficiaryId);
    error AlreadyRegistered(address account);
    error InactiveBeneficiary(uint256 beneficiaryId);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OFFICER_ROLE, msg.sender);
        _grantRole(COMMITTEE_ROLE, msg.sender);
    }

    modifier onlyOfficer() {
        if (!hasRole(OFFICER_ROLE, msg.sender)) revert NotOfficer();
        _;
    }

    /* ==================== DONORS ==================== */

    function registerDonor() external returns (address donor) {
        donor = msg.sender;
        if (isDonor[donor]) revert AlreadyRegistered(donor);
        isDonor[donor] = true;
        emit DonorRegistered(donor);
    }

    /* ==================== BENEFICIARIES ==================== */

    function registerBeneficiary(
        bytes32 nameHash,
        Category category,
        uint256 monthlyNeed,
        string calldata purpose
    ) external onlyOfficer returns (uint256 beneficiaryId) {
        if (category == Category.None) revert ZeroAddress();
        if (nameHash == bytes32(0) || monthlyNeed == 0) revert ZeroAddress();
        beneficiaryId = beneficiaries.length;
        beneficiaries.push();
        Beneficiary storage b = beneficiaries[beneficiaryId];
        b.nameHash = nameHash;
        b.category = category;
        b.monthlyNeed = monthlyNeed;
        b.purpose = purpose;
        b.verified = true;
        b.active = true;
        beneficiaryCount += 1;
        emit BeneficiaryRegistered(beneficiaryId, category, monthlyNeed);
    }

    function updateBeneficiary(
        uint256 beneficiaryId,
        uint256 monthlyNeed,
        string calldata purpose
    ) external onlyOfficer {
        Beneficiary storage b = beneficiaries[beneficiaryId];
        if (b.nameHash == bytes32(0)) revert UnknownBeneficiary(beneficiaryId);
        b.monthlyNeed = monthlyNeed;
        b.purpose = purpose;
        emit BeneficiaryUpdated(beneficiaryId);
    }

    function deactivateBeneficiary(uint256 beneficiaryId) external onlyOfficer {
        Beneficiary storage b = beneficiaries[beneficiaryId];
        if (b.nameHash == bytes32(0)) revert UnknownBeneficiary(beneficiaryId);
        b.active = false;
        emit BeneficiaryDeactivated(beneficiaryId);
    }

    function isActiveBeneficiary(uint256 beneficiaryId) external view returns (bool) {
        if (beneficiaryId >= beneficiaries.length) return false;
        return beneficiaries[beneficiaryId].active && beneficiaries[beneficiaryId].verified;
    }
}
