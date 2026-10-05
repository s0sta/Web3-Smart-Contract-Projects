// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {DamanRegistry} from "./DamanRegistry.sol";
import {DamanPricing, DamanLines} from "./DamanPricing.sol";
import {DamanPremiums} from "./DamanPremiums.sol";
import {DamanTreasury} from "./DamanTreasury.sol";

/// @title DamanPolicies
/// @notice The policy lifecycle: policyholders buy priced covers; premiums are
///         split into the line pool and the platform fee; policies expire or
///         are closed by a claim.
contract DamanPolicies is AccessControl {
    /// @notice The claims desk marks policies claimed.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR");

    /// @notice Policy states.
    enum Status { Active, Expired, Claimed }

    /// @notice One policy.
    struct Policy {
        address holder;
        DamanLines.Line line;
        DamanPricing.RiskClass riskClass;
        uint256 cover;
        uint256 premium;
        uint64 startAt;
        uint64 endAt;
        bool noClaim; // survives without a paid claim
        Status status;
    }

    Policy[] public policies;
    mapping(address holder => uint256[]) public policiesOf;

    /// @notice Per-line minimum and maximum cover.
    mapping(DamanLines.Line line => uint256) public minCover;
    mapping(DamanLines.Line line => uint256) public maxCover;

    DamanRegistry public immutable registry;
    DamanPricing public immutable pricing;
    DamanPremiums public immutable premiums;
    DamanTreasury public immutable treasury;
    IERC20 public immutable paymentToken;

    /// @notice Platform fee share of each premium (bps).
    uint256 public platformFeeBps;

    event PolicyPurchased(uint256 indexed policyId, address indexed holder, DamanLines.Line line, uint256 cover, uint256 premium);
    event PolicyExpired(uint256 indexed policyId);
    event PolicyClaimed(uint256 indexed policyId);
    event LimitsSet(DamanLines.Line line, uint256 minCover, uint256 maxCover);
    event FeeSet(uint256 bps);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownPolicy(uint256 policyId);
    error NotHolder(uint256 policyId);
    error CoverOutOfBounds(uint256 cover, uint256 min, uint256 max);
    error PolicyInactive(uint256 policyId);
    error TransferFailed();

    constructor(
        DamanRegistry registry_,
        DamanPricing pricing_,
        DamanPremiums premiums_,
        DamanTreasury treasury_,
        IERC20 paymentToken_
    ) {
        if (address(registry_) == address(0) || address(pricing_) == address(0) || address(premiums_) == address(0) || address(treasury_) == address(0) || address(paymentToken_) == address(0)) {
            revert ZeroAddress();
        }
        registry = registry_;
        pricing = pricing_;
        premiums = premiums_;
        treasury = treasury_;
        paymentToken = paymentToken_;
        platformFeeBps = 500; // 5%
        minCover[DamanLines.Line.Travel] = 100 ether;
        maxCover[DamanLines.Line.Travel] = 100_000 ether;
        minCover[DamanLines.Line.FlightDelay] = 50 ether;
        maxCover[DamanLines.Line.FlightDelay] = 5_000 ether;
        minCover[DamanLines.Line.Property] = 500 ether;
        maxCover[DamanLines.Line.Property] = 500_000 ether;
        minCover[DamanLines.Line.Health] = 100 ether;
        maxCover[DamanLines.Line.Health] = 50_000 ether;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /* ==================== PURCHASE ==================== */

    function buyPolicy(
        DamanLines.Line line,
        DamanPricing.RiskClass rc,
        uint256 cover,
        uint256 durationDays
    ) external returns (uint256 policyId) {
        if (!registry.isActive(msg.sender)) revert ZeroAmount();
        uint256 min = minCover[line];
        uint256 max = maxCover[line];
        if (cover < min || cover > max) revert CoverOutOfBounds(cover, min, max);
        uint256 premium = pricing.quote(line, rc, cover, durationDays);
        if (premium == 0) revert ZeroAmount();

        uint256 fee = (premium * platformFeeBps) / 10_000;
        uint256 poolShare = premium - fee;
        if (!paymentToken.transferFrom(msg.sender, address(this), premium)) revert TransferFailed();
        if (poolShare > 0) {
            if (!paymentToken.approve(address(premiums), poolShare)) revert TransferFailed();
            premiums.receivePremium(line, poolShare);
        }
        if (fee > 0) {
            if (!paymentToken.approve(address(treasury), fee)) revert TransferFailed();
            treasury.receiveFees(fee);
        }

        policyId = policies.length;
        policies.push();
        Policy storage p = policies[policyId];
        p.holder = msg.sender;
        p.line = line;
        p.riskClass = rc;
        p.cover = cover;
        p.premium = premium;
        p.startAt = uint64(block.timestamp);
        p.endAt = uint64(block.timestamp + durationDays * 1 days);
        p.noClaim = true;
        p.status = Status.Active;
        policiesOf[msg.sender].push(policyId);
        emit PolicyPurchased(policyId, msg.sender, line, cover, premium);
    }

    /* ==================== LIFECYCLE ==================== */

    function expire(uint256 policyId) external {
        Policy storage p = policies[policyId];
        if (p.holder == address(0)) revert UnknownPolicy(policyId);
        if (p.status != Status.Active) revert PolicyInactive(policyId);
        if (block.timestamp < p.endAt) revert PolicyInactive(policyId);
        p.status = Status.Expired;
        emit PolicyExpired(policyId);
    }

    /// @notice The claims desk marks a policy claimed and records the payout.
    function markClaimed(uint256 policyId, address claimsDesk) external returns (uint256 cover) {
        // the claims desk is granted the operator role below
        if (!hasRole(OPERATOR_ROLE, msg.sender)) revert ZeroAmount();
        Policy storage p = policies[policyId];
        if (p.holder == address(0)) revert UnknownPolicy(policyId);
        if (p.status != Status.Active) revert PolicyInactive(policyId);
        if (block.timestamp > p.endAt) revert PolicyInactive(policyId);
        p.status = Status.Claimed;
        p.noClaim = false;
        cover = p.cover;
        claimsDesk; // the claims desk performs the payout
        emit PolicyClaimed(policyId);
    }

    function isActivePolicy(uint256 policyId) external view returns (bool) {
        Policy storage p = policies[policyId];
        return p.status == Status.Active && block.timestamp <= p.endAt;
    }

    function policiesOfList(address holder) external view returns (uint256[] memory) {
        return policiesOf[holder];
    }

    /* ==================== ADMIN ==================== */

    function setLimits(DamanLines.Line line, uint256 minCover_, uint256 maxCover_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        minCover[line] = minCover_;
        maxCover[line] = maxCover_;
        emit LimitsSet(line, minCover_, maxCover_);
    }

    function setPlatformFee(uint256 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > 2000) revert ZeroAmount();
        platformFeeBps = bps;
        emit FeeSet(bps);
    }
}
