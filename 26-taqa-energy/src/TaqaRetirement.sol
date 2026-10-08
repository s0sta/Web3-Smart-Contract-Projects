// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {TaqaRegistry} from "./TaqaRegistry.sol";
import {TaqaCertificates} from "./TaqaCertificates.sol";
import {TaqaCarbon} from "./TaqaCarbon.sol";

/// @title TaqaRetirement
/// @notice The green-claims registry: holders retire certificates and credits
///         against named claims (ESG reports, product lines). Every unit can
///         only be retired once — no double counting.
contract TaqaRetirement is AccessControl {
    /// @notice One retirement entry.
    struct Retirement {
        address retirer;
        bool isRec;
        uint256 amount;
        string claim;
        uint64 retiredAt;
    }

    Retirement[] public retirements;
    mapping(address retirer => uint256[]) public retirementsOf;

    /// @notice Retired totals per holder (for ESG reporting).
    mapping(address retirer => uint256) public retiredRec;
    mapping(address retirer => uint256) public retiredCarbon;

    TaqaRegistry public immutable registry;
    TaqaCertificates public immutable certificates;
    TaqaCarbon public immutable carbon;

    event Retired(uint256 indexed retirementId, address indexed retirer, bool isRec, uint256 amount, string claim);

    error ZeroAddress();
    error ZeroAmount();
    error NotOwner();
    error InsufficientBalance(uint256 balance, uint256 amount);

    constructor(TaqaRegistry registry_, TaqaCertificates certificates_, TaqaCarbon carbon_) {
        if (address(registry_) == address(0) || address(certificates_) == address(0) || address(carbon_) == address(0)) {
            revert ZeroAddress();
        }
        registry = registry_;
        certificates = certificates_;
        carbon = carbon_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /* ==================== RETIREMENT ==================== */

    function retireRec(uint256 amount, string calldata claim) external returns (uint256 retirementId) {
        if (amount == 0) revert ZeroAmount();
        uint256 bal = certificates.balanceOf(msg.sender);
        if (bal < amount) revert InsufficientBalance(bal, amount);
        certificates.retireFrom(msg.sender, amount);
        retiredRec[msg.sender] += amount;
        retirementId = retirements.length;
        retirements.push();
        Retirement storage r = retirements[retirementId];
        r.retirer = msg.sender;
        r.isRec = true;
        r.amount = amount;
        r.claim = claim;
        r.retiredAt = uint64(block.timestamp);
        retirementsOf[msg.sender].push(retirementId);
        emit Retired(retirementId, msg.sender, true, amount, claim);
    }

    function retireCarbon(uint256 amount, string calldata claim) external returns (uint256 retirementId) {
        if (amount == 0) revert ZeroAmount();
        uint256 bal = carbon.balanceOf(msg.sender);
        if (bal < amount) revert InsufficientBalance(bal, amount);
        carbon.retireFrom(msg.sender, amount);
        retiredCarbon[msg.sender] += amount;
        retirementId = retirements.length;
        retirements.push();
        Retirement storage r = retirements[retirementId];
        r.retirer = msg.sender;
        r.isRec = false;
        r.amount = amount;
        r.claim = claim;
        r.retiredAt = uint64(block.timestamp);
        retirementsOf[msg.sender].push(retirementId);
        emit Retired(retirementId, msg.sender, false, amount, claim);
    }

    function retirementsOfList(address retirer) external view returns (uint256[] memory) {
        return retirementsOf[retirer];
    }
}
