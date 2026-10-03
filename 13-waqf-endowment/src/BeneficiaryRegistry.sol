// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";

/// @title BeneficiaryRegistry
/// @notice The awqaf beneficiary register: named beneficiaries with weights in basis
///         points (they must sum to 10,000). Weight changes take effect from the next
///         distribution, and every change is recorded on-chain for the regulator.
///
/// @dev The registry is managed by the nazir board and the WaqfGovernor; the vault
///      reads weights directly for distributions.
contract BeneficiaryRegistry is AccessControl {
    /// @notice The nazir (trustee) board.
    bytes32 public constant NAZIR_ROLE = keccak256("NAZIR");

    /// @notice The WaqfGovernor (grants access so governance proposals can take effect).
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR");

    /// @notice One registered beneficiary.
    struct Beneficiary {
        address account;
        uint256 weightBps; // share of distributions (basis points)
        bool active;
    }

    /// @notice The register.
    mapping(uint256 id => Beneficiary) public beneficiaries;
    uint256 public beneficiaryCount;

    /// @notice Sum of active weights (should equal 10,000 before distributing).
    uint256 public totalActiveWeight;

    event BeneficiaryAdded(uint256 indexed id, address indexed account, uint256 weightBps);
    event BeneficiaryWeightSet(uint256 indexed id, uint256 oldWeight, uint256 newWeight);
    event BeneficiaryDeactivated(uint256 indexed id);

    error ZeroAddress();
    error InvalidWeight();
    error UnknownBeneficiary(uint256 id);
    error AlreadyActive();
    error NotActive(uint256 id);
    error WeightOverflow();

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(NAZIR_ROLE, msg.sender);
        _grantRole(GOVERNOR_ROLE, msg.sender);
    }

    /// @notice Registers a new beneficiary with a weight.
    function addBeneficiary(address account, uint256 weightBps) external onlyRole(NAZIR_ROLE) returns (uint256 id) {
        if (account == address(0)) revert ZeroAddress();
        if (weightBps == 0 || weightBps > 10_000) revert InvalidWeight();
        if (totalActiveWeight + weightBps > 10_000) revert WeightOverflow();

        id = beneficiaryCount++;
        beneficiaries[id] = Beneficiary({ account: account, weightBps: weightBps, active: true });
        totalActiveWeight += weightBps;
        emit BeneficiaryAdded(id, account, weightBps);
    }

    /// @notice Adjusts an existing beneficiary's weight (nazir or governor).
    function setBeneficiaryWeight(uint256 id, uint256 newWeightBps) external {
        if (!hasRole(NAZIR_ROLE, msg.sender) && !hasRole(GOVERNOR_ROLE, msg.sender)) revert();
        Beneficiary storage b = beneficiaries[id];
        if (!b.active) revert NotActive(id);
        if (newWeightBps == 0 || newWeightBps > 10_000) revert InvalidWeight();

        uint256 newTotal = totalActiveWeight - b.weightBps + newWeightBps;
        if (newTotal > 10_000) revert WeightOverflow();

        emit BeneficiaryWeightSet(id, b.weightBps, newWeightBps);
        totalActiveWeight = newTotal;
        b.weightBps = newWeightBps;
    }

    /// @notice Deactivates a beneficiary (nazir or governor).
    function deactivateBeneficiary(uint256 id) external {
        if (!hasRole(NAZIR_ROLE, msg.sender) && !hasRole(GOVERNOR_ROLE, msg.sender)) revert();
        Beneficiary storage b = beneficiaries[id];
        if (!b.active) revert NotActive(id);
        b.active = false;
        totalActiveWeight -= b.weightBps;
        emit BeneficiaryDeactivated(id);
    }

    /// @notice The governor grants itself this role once deployed.
    function setGovernor(address governor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (governor == address(0)) revert ZeroAddress();
        _grantRole(GOVERNOR_ROLE, governor);
    }

    /// @notice Builds the arrays the vault's distribute() expects.
    function distributionTargets() external view returns (address[] memory accounts, uint256[] memory weights) {
        uint256 count = 0;
        for (uint256 i = 0; i < beneficiaryCount; i++) {
            if (beneficiaries[i].active) count++;
        }
        accounts = new address[](count);
        weights = new uint256[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < beneficiaryCount; i++) {
            Beneficiary storage b = beneficiaries[i];
            if (b.active) {
                accounts[idx] = b.account;
                weights[idx] = b.weightBps;
                idx++;
            }
        }
    }
}
