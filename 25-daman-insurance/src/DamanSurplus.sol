// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {DamanPolicies} from "./DamanPolicies.sol";
import {DamanPremiums} from "./DamanPremiums.sol";
import {DamanLines} from "./DamanPricing.sol";

/// @title DamanSurplus
/// @notice The mutual rebate: at each period close, the surplus of a line pool
///         (the pool above the period's reserve) is distributed pro-rata to
///         policyholders who closed the period without a claim.
contract DamanSurplus is AccessControl {
    /// @notice The operator closes periods.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR");

    /// @notice Reserve share of the period's premiums that never distributes.
    uint256 public reserveBps;

    mapping(DamanLines.Line line => uint256) public period;
    mapping(DamanLines.Line line => uint256) public distributed;

    DamanPolicies public immutable policies;
    DamanPremiums public immutable premiums;

    event SurplusDistributed(DamanLines.Line line, uint256 period, uint256 amount);
    event ReserveSet(uint256 bps);

    error ZeroAddress();
    error ZeroAmount();
    error NothingToDistribute(DamanLines.Line line);
    error TransferFailed();

    constructor(DamanPolicies policies_, DamanPremiums premiums_) {
        if (address(policies_) == address(0) || address(premiums_) == address(0)) revert ZeroAddress();
        policies = policies_;
        premiums = premiums_;
        reserveBps = 2000; // 20%
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    /// @notice Closes the period for a line: the surplus is distributed
    ///         pro-rata to the listed no-claim policyholders of the period.
    function distributeSurplus(
        DamanLines.Line line,
        uint256[] calldata noClaimPolicyIds,
        uint256 periodPremiums
    ) external onlyRole(OPERATOR_ROLE) {
        uint256 available = premiums.pool(line);
        uint256 reserve = (periodPremiums * reserveBps) / 10_000;
        uint256 surplus = available > reserve ? available - reserve : 0;
        if (surplus == 0) revert NothingToDistribute(line);
        if (noClaimPolicyIds.length == 0) revert ZeroAmount();

        uint256 share = surplus / noClaimPolicyIds.length;
        if (share == 0) revert NothingToDistribute(line);

        uint256 total;
        for (uint256 i = 0; i < noClaimPolicyIds.length; i++) {
            (address holder, DamanLines.Line l, , , , , , bool noClaim, DamanPolicies.Status status) = policies.policies(noClaimPolicyIds[i]);
            if (l != line || !noClaim) continue;
            if (status != DamanPolicies.Status.Expired) continue;
            premiums.paySurplus(line, share, holder);
            total += share;
        }
        if (total == 0) revert NothingToDistribute(line);
        distributed[line] += total;
        period[line] += 1;
        emit SurplusDistributed(line, period[line], total);
    }

    function setReserve(uint256 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > 5000) revert ZeroAmount();
        reserveBps = bps;
        emit ReserveSet(bps);
    }
}
