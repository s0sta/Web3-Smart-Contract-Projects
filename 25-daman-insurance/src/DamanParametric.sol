// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {DamanRegistry} from "./DamanRegistry.sol";
import {DamanOracle} from "./DamanOracle.sol";
import {DamanPremiums} from "./DamanPremiums.sol";
import {DamanTreasury} from "./DamanTreasury.sol";
import {DamanLines} from "./DamanPricing.sol";

/// @title DamanParametric
/// @notice The parametric desk: holders buy coverage that pays automatically
///         when an oracle condition triggers inside the window — no adjusters,
///         no disputes, just data.
contract DamanParametric is AccessControl {
    /// @notice One parametric cover.
    struct Cover {
        address holder;
        uint256 conditionId;
        uint256 payout;
        uint256 premium;
        uint64 startAt;
        uint64 endAt;
        bool paid;
    }

    Cover[] public covers;
    mapping(address holder => uint256[]) public coversOf;

    /// @notice Premium rate (bps of the payout) and per-condition payout cap.
    uint256 public rateBps;
    mapping(uint256 conditionId => uint256) public conditionCap;

    DamanRegistry public immutable registry;
    DamanOracle public immutable oracle;
    DamanPremiums public immutable premiums;
    DamanTreasury public immutable treasury;
    IERC20 public immutable paymentToken;

    event CoverBought(uint256 indexed coverId, address indexed holder, uint256 conditionId, uint256 payout, uint256 premium);
    event CoverTriggered(uint256 indexed coverId, uint256 payout);
    event CoverExpired(uint256 indexed coverId);
    event RateSet(uint256 bps);
    event CapSet(uint256 conditionId, uint256 cap);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownCover(uint256 coverId);
    error NotHolder(uint256 coverId);
    error WindowClosed(uint256 coverId);
    error AlreadyPaid(uint256 coverId);
    error ConditionInactive(uint256 conditionId);
    error CapExceeded(uint256 conditionId, uint256 cap);
    error TransferFailed();

    constructor(
        DamanRegistry registry_,
        DamanOracle oracle_,
        DamanPremiums premiums_,
        DamanTreasury treasury_,
        IERC20 paymentToken_
    ) {
        if (address(registry_) == address(0) || address(oracle_) == address(0) || address(premiums_) == address(0) || address(treasury_) == address(0) || address(paymentToken_) == address(0)) {
            revert ZeroAddress();
        }
        registry = registry_;
        oracle = oracle_;
        premiums = premiums_;
        treasury = treasury_;
        paymentToken = paymentToken_;
        rateBps = 600; // 6%
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /* ==================== PURCHASE ==================== */

    function buyCover(uint256 conditionId, uint256 payout, uint64 windowDays) external returns (uint256 coverId) {
        if (!registry.isActive(msg.sender)) revert ZeroAmount();
        if (payout == 0 || windowDays == 0) revert ZeroAmount();
        uint256 cap = conditionCap[conditionId];
        if (cap != 0 && payout > cap) revert CapExceeded(conditionId, cap);
        ( , , , , bool active) = oracle.conditions(conditionId);
        if (!active) revert ConditionInactive(conditionId);

        uint256 premium = (payout * rateBps) / 10_000;
        uint256 fee = (premium * 500) / 10_000; // 5% platform fee
        uint256 poolShare = premium - fee;
        if (!paymentToken.transferFrom(msg.sender, address(this), premium)) revert TransferFailed();
        if (poolShare > 0) {
            if (!paymentToken.approve(address(premiums), poolShare)) revert TransferFailed();
            premiums.receivePremium(DamanLines.Line.FlightDelay, poolShare);
        }
        if (fee > 0) {
            if (!paymentToken.approve(address(treasury), fee)) revert TransferFailed();
            treasury.receiveFees(fee);
        }

        coverId = covers.length;
        covers.push();
        Cover storage c = covers[coverId];
        c.holder = msg.sender;
        c.conditionId = conditionId;
        c.payout = payout;
        c.premium = premium;
        c.startAt = uint64(block.timestamp);
        c.endAt = uint64(block.timestamp + windowDays * 1 days);
        coversOf[msg.sender].push(coverId);
        emit CoverBought(coverId, msg.sender, conditionId, payout, premium);
    }

    /* ==================== SETTLEMENT ==================== */

    /// @notice After the window closes, anyone settles: triggered covers pay out.
    function settle(uint256 coverId) external {
        Cover storage c = covers[coverId];
        if (c.holder == address(0)) revert UnknownCover(coverId);
        if (c.paid) revert AlreadyPaid(coverId);
        if (block.timestamp < c.endAt) revert WindowClosed(coverId);
        c.paid = true;
        bool triggered = oracle.checkCondition(c.conditionId);
        if (triggered) {
            premiums.payParametric(DamanLines.Line.FlightDelay, c.payout, c.holder);
            emit CoverTriggered(coverId, c.payout);
        } else {
            emit CoverExpired(coverId);
        }
    }

    function coversOfList(address holder) external view returns (uint256[] memory) {
        return coversOf[holder];
    }

    /* ==================== ADMIN ==================== */

    function setRate(uint256 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > 5000) revert ZeroAmount();
        rateBps = bps;
        emit RateSet(bps);
    }

    function setCap(uint256 conditionId, uint256 cap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        conditionCap[conditionId] = cap;
        emit CapSet(conditionId, cap);
    }
}
