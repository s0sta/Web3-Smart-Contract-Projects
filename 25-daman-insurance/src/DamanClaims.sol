// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {DamanRegistry} from "./DamanRegistry.sol";
import {DamanPolicies} from "./DamanPolicies.sol";
import {DamanPremiums} from "./DamanPremiums.sol";
import {DamanLines} from "./DamanPricing.sol";

/// @title DamanClaims
/// @notice The claims desk: policyholders file claims with evidence hashes;
///         a 2-of-3 adjuster panel votes; approved claims draw from the line
///         pool and mark the policy claimed.
contract DamanClaims is AccessControl {
    /// @notice Adjusters vote on claims.
    bytes32 public constant ADJUSTER_ROLE = keccak256("ADJUSTER");

    /// @notice One claim.
    struct Claim {
        uint256 policyId;
        address claimant;
        uint256 amount;
        string reason;
        bytes32 evidenceHash;
        mapping(address adjuster => bool) voted;
        uint256 approvals;
        uint256 rejections;
        bool decided;
        bool approved;
    }

    Claim[] public claims;

    DamanRegistry public immutable registry;
    DamanPolicies public immutable policies;
    DamanPremiums public immutable premiums;

    event ClaimFiled(uint256 indexed claimId, uint256 policyId, address indexed claimant, uint256 amount);
    event ClaimVoted(uint256 indexed claimId, address indexed adjuster, bool approve);
    event ClaimPaid(uint256 indexed claimId, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownClaim(uint256 claimId);
    error AlreadyDecided(uint256 claimId);
    error AlreadyVoted(uint256 claimId, address adjuster);
    error NotAdjuster();
    error PolicyInactive(uint256 policyId);

    constructor(DamanRegistry registry_, DamanPolicies policies_, DamanPremiums premiums_) {
        if (address(registry_) == address(0) || address(policies_) == address(0) || address(premiums_) == address(0)) {
            revert ZeroAddress();
        }
        registry = registry_;
        policies = policies_;
        premiums = premiums_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADJUSTER_ROLE, msg.sender);
    }

    /* ==================== FILING ==================== */

    function fileClaim(uint256 policyId, uint256 amount, string calldata reason, bytes32 evidenceHash) external returns (uint256 claimId) {
        if (amount == 0) revert ZeroAmount();
        if (!policies.isActivePolicy(policyId)) revert PolicyInactive(policyId);
        (address holder, , , uint256 cover, , , , , ) = policies.policies(policyId);
        if (msg.sender != holder) revert NotAdjuster();
        if (amount > cover) revert ZeroAmount();
        if (evidenceHash == bytes32(0)) revert ZeroAmount();

        claimId = claims.length;
        claims.push();
        Claim storage c = claims[claimId];
        c.policyId = policyId;
        c.claimant = msg.sender;
        c.amount = amount;
        c.reason = reason;
        c.evidenceHash = evidenceHash;
        emit ClaimFiled(claimId, policyId, msg.sender, amount);
    }

    /* ==================== VOTING ==================== */

    function voteClaim(uint256 claimId, bool approve) external onlyRole(ADJUSTER_ROLE) {
        Claim storage c = claims[claimId];
        if (c.claimant == address(0)) revert UnknownClaim(claimId);
        if (c.decided) revert AlreadyDecided(claimId);
        if (c.voted[msg.sender]) revert AlreadyVoted(claimId, msg.sender);

        c.voted[msg.sender] = true;
        if (approve) c.approvals += 1;
        else c.rejections += 1;
        emit ClaimVoted(claimId, msg.sender, approve);

        if (c.approvals >= 2) {
            c.decided = true;
            c.approved = true;
            _settle(claimId);
        } else if (c.rejections >= 2) {
            c.decided = true;
        }
    }

    function _settle(uint256 claimId) internal {
        Claim storage c = claims[claimId];
        ( , DamanLines.Line line, , , , , , , ) = policies.policies(c.policyId);
        premiums.payClaim(line, c.amount, c.claimant);
        policies.markClaimed(c.policyId, address(this));
        emit ClaimPaid(claimId, c.amount);
    }
}
