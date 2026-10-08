// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {TaqaRegistry} from "./TaqaRegistry.sol";
import {TaqaOracle} from "./TaqaOracle.sol";
import {TaqaTreasury} from "./TaqaTreasury.sol";

/// @title TaqaP2P
/// @notice Peer-to-peer energy trading: producers post kWh offers at a tariff;
///         consumers buy; settlement happens in the stable per kWh, with
///         net-metering batches the operator closes periodically.
contract TaqaP2P is AccessControl {
    /// @notice The operator closes settlement batches.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR");

    /// @notice One offer.
    struct Offer {
        address producer;
        uint256 kwh;
        uint256 pricePerKwh;
        uint256 soldKwh;
        bool active;
    }

    Offer[] public offers;

    /// @notice Metered consumption balances for netting (kWh).
    mapping(address consumer => uint256) public consumedKwh;
    mapping(address producer => uint256) public suppliedKwh;

    uint256 public feeBps;
    uint256 public totalVolume;

    TaqaRegistry public immutable registry;
    TaqaOracle public immutable oracle;
    TaqaTreasury public immutable treasury;
    IERC20 public immutable paymentToken;

    event OfferPosted(uint256 indexed offerId, address indexed producer, uint256 kwh, uint256 pricePerKwh);
    event EnergyBought(uint256 indexed offerId, address indexed consumer, uint256 kwh, uint256 cost);
    event OfferClosed(uint256 indexed offerId);
    event BatchSettled(uint256 period, uint256 totalKwh, uint256 totalValue);
    event FeeSet(uint256 bps);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownOffer(uint256 offerId);
    error OfferInactive(uint256 offerId);
    error NotProducer(uint256 offerId);
    error InsufficientKwh(uint256 available, uint256 needed);
    error TransferFailed();

    constructor(
        TaqaRegistry registry_,
        TaqaOracle oracle_,
        TaqaTreasury treasury_,
        IERC20 paymentToken_
    ) {
        if (address(registry_) == address(0) || address(oracle_) == address(0) || address(treasury_) == address(0) || address(paymentToken_) == address(0)) {
            revert ZeroAddress();
        }
        registry = registry_;
        oracle = oracle_;
        treasury = treasury_;
        paymentToken = paymentToken_;
        feeBps = 30; // 0.3%
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    /* ==================== OFFERS ==================== */

    function postOffer(uint256 kwh, uint256 pricePerKwh) external returns (uint256 offerId) {
        if (kwh == 0 || pricePerKwh == 0) revert ZeroAmount();
        if (!registry.isActive(msg.sender)) revert ZeroAmount();
        if (registry.roleOf(msg.sender) != TaqaRegistry.Role.Producer) revert NotProducer(0);

        offerId = offers.length;
        offers.push();
        Offer storage o = offers[offerId];
        o.producer = msg.sender;
        o.kwh = kwh;
        o.pricePerKwh = pricePerKwh;
        o.active = true;
        emit OfferPosted(offerId, msg.sender, kwh, pricePerKwh);
    }

    function buy(uint256 offerId, uint256 kwh) external {
        Offer storage o = offers[offerId];
        if (o.producer == address(0)) revert UnknownOffer(offerId);
        if (!o.active) revert OfferInactive(offerId);
        if (kwh == 0) revert ZeroAmount();
        uint256 remaining = o.kwh - o.soldKwh;
        if (kwh > remaining) revert InsufficientKwh(remaining, kwh);
        if (!registry.isActive(msg.sender)) revert ZeroAmount();

        uint256 cost = (kwh * o.pricePerKwh) / 1e18;
        uint256 fee = (cost * feeBps) / 10_000;
        o.soldKwh += kwh;
        consumedKwh[msg.sender] += kwh;
        suppliedKwh[o.producer] += kwh;
        totalVolume += cost;

        if (!paymentToken.transferFrom(msg.sender, o.producer, cost - fee)) revert TransferFailed();
        if (fee > 0) {
            if (!paymentToken.transferFrom(msg.sender, address(this), fee)) revert TransferFailed();
            if (!paymentToken.approve(address(treasury), fee)) revert TransferFailed();
            treasury.receiveFees(fee);
        }
        emit EnergyBought(offerId, msg.sender, kwh, cost);
        if (o.soldKwh == o.kwh) {
            o.active = false;
            emit OfferClosed(offerId);
        }
    }

    /// @notice Closes a settlement period (net-metering bookkeeping).
    function settleBatch(uint256 totalKwh, uint256 totalValue) external onlyRole(OPERATOR_ROLE) {
        emit BatchSettled(block.timestamp / 1 days, totalKwh, totalValue);
    }

    function setFee(uint256 bps) external onlyRole(OPERATOR_ROLE) {
        if (bps > 1000) revert ZeroAmount();
        feeBps = bps;
        emit FeeSet(bps);
    }
}
