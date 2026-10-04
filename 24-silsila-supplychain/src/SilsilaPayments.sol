// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {SilsilaRegistry} from "./SilsilaRegistry.sol";
import {SilsilaOrders} from "./SilsilaOrders.sol";
import {SilsilaShipments} from "./SilsilaShipments.sol";
import {SilsilaTreasury} from "./SilsilaTreasury.sol";

/// @title SilsilaPayments
/// @notice The settlement desk: the buyer funds the order value into escrow;
///         releases follow shipment milestones (e.g. 30% on packing, 70% on
///         delivery); the carrier is paid per leg; cancellations refund and
///         late deliveries trigger a penalty to the buyer.
contract SilsilaPayments is AccessControl {
    /// @notice The operator adjusts the milestone split and penalties.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR");

    /// @notice One escrow.
    struct Escrow {
        uint256 orderId;
        address buyer;
        uint256 funded;
        uint256 released;
        uint256 carrierPaid;
        uint256 penaltyPaid;
        bool settled;
    }

    Escrow[] public escrows;
    mapping(uint256 orderId => uint256) public escrowOfOrder;

    /// @notice Release percentage when the shipment reaches each milestone (bps).
    mapping(uint8 milestone => uint256) public releaseBps;

    /// @notice Platform fee (bps) on each release.
    uint256 public platformFeeBps;

    /// @notice Late-delivery penalty (bps of the remaining order value).
    uint256 public latePenaltyBps;

    /// @notice Carrier payment (bps of the order value) paid on delivery.
    uint256 public carrierBps;

    SilsilaRegistry public immutable registry;
    SilsilaOrders public immutable orders;
    SilsilaShipments public immutable shipments;
    SilsilaTreasury public immutable treasury;
    IERC20 public immutable paymentToken;

    event EscrowFunded(uint256 indexed escrowId, uint256 orderId, uint256 amount);
    event Released(uint256 indexed escrowId, uint8 milestone, uint256 amount);
    event CarrierPaid(uint256 indexed escrowId, address indexed carrier, uint256 amount);
    event PenaltyPaid(uint256 indexed escrowId, uint256 amount);
    event Refunded(uint256 indexed escrowId, uint256 amount);
    event SplitSet(uint8 milestone, uint256 bps);
    event FeesSet(uint256 platformBps, uint256 penaltyBps, uint256 carrierBps);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownEscrow(uint256 escrowId);
    error AlreadyFunded(uint256 orderId);
    error NotFunded(uint256 escrowId);
    error NotBuyer(uint256 escrowId);
    error AlreadyReleased(uint256 escrowId, uint8 milestone);
    error NothingToRelease(uint256 escrowId);
    error NotDelivered(uint256 escrowId);
    error TransferFailed();

    constructor(
        SilsilaRegistry registry_,
        SilsilaOrders orders_,
        SilsilaShipments shipments_,
        SilsilaTreasury treasury_,
        IERC20 paymentToken_
    ) {
        if (address(registry_) == address(0) || address(orders_) == address(0) || address(shipments_) == address(0) || address(treasury_) == address(0) || address(paymentToken_) == address(0)) {
            revert ZeroAddress();
        }
        registry = registry_;
        orders = orders_;
        shipments = shipments_;
        treasury = treasury_;
        paymentToken = paymentToken_;
        releaseBps[uint8(SilsilaShipments.Milestone.Packed)] = 3000; // 30%
        releaseBps[uint8(SilsilaShipments.Milestone.Delivered)] = 7000; // 70%
        platformFeeBps = 50; // 0.5%
        latePenaltyBps = 500; // 5%
        carrierBps = 300; // 3% of the order value to the carrier
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    /* ==================== FUNDING ==================== */

    function fund(uint256 orderId, uint256 amount) external returns (uint256 escrowId) {
        (address buyer, , uint256 quantity, , uint256 unitPrice, , , , , , SilsilaOrders.Status status) = orders.orders(orderId);
        if (status == SilsilaOrders.Status.Canceled || status == SilsilaOrders.Status.Rejected) revert ZeroAmount();
        if (msg.sender != buyer) revert NotBuyer(0);
        if (escrowOfOrder[orderId] != 0) revert AlreadyFunded(orderId);
        uint256 value = quantity * unitPrice;
        if (amount != value) revert ZeroAmount();

        escrowId = escrows.length;
        escrows.push();
        Escrow storage e = escrows[escrowId];
        e.orderId = orderId;
        e.buyer = buyer;
        e.funded = amount;
        escrowOfOrder[orderId] = escrowId + 1;
        if (!paymentToken.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        emit EscrowFunded(escrowId, orderId, amount);
    }

    /* ==================== RELEASES ==================== */

    /// @notice Releases the milestone's share to the supplier when the shipment
    ///         has reached (or passed) that milestone.
    function release(uint256 escrowId, uint8 milestone) external returns (uint256 amount) {
        Escrow storage e = escrows[escrowId];
        if (e.buyer == address(0)) revert UnknownEscrow(escrowId);
        if (e.funded == 0) revert NotFunded(escrowId);
        uint256 bps = releaseBps[milestone];
        if (bps == 0) revert NothingToRelease(escrowId);
        uint256 shipped = shipmentOfOrder(e.orderId);
        if (shipped == 0) revert NotDelivered(escrowId);
        ( , , SilsilaShipments.Milestone current, , , , , ) = shipments.shipments(shipped - 1);
        if (uint8(current) < milestone) revert NotDelivered(escrowId);
        amount = (e.funded * bps) / 10_000;
        if (amount == 0 || amount + e.released > e.funded) revert NothingToRelease(escrowId);
        e.released += amount;

        ( , address supplier, , , , , , , , , ) = orders.orders(e.orderId);
        uint256 fee = (amount * platformFeeBps) / 10_000;
        uint256 net = amount - fee;
        if (!paymentToken.transfer(supplier, net)) revert TransferFailed();
        if (fee > 0) {
            if (!paymentToken.approve(address(treasury), fee)) revert TransferFailed();
            treasury.receiveFees(fee);
        }
        emit Released(escrowId, milestone, amount);

        // on delivery: pay the carrier and apply the late penalty if any
        if (milestone == uint8(SilsilaShipments.Milestone.Delivered)) {
            _settleDelivery(escrowId);
        }
    }

    function _settleDelivery(uint256 escrowId) internal {
        Escrow storage e = escrows[escrowId];
        if (e.settled) return;
        e.settled = true;
        uint256 shipped = shipmentOfOrder(e.orderId);
        ( , address carrier, , , , bool onTime, , ) = shipments.shipments(shipped - 1);
        uint256 carrierPay = (e.funded * carrierBps) / 10_000;
        if (carrierPay > 0) {
            e.carrierPaid = carrierPay;
            if (!paymentToken.transfer(carrier, carrierPay)) revert TransferFailed();
            emit CarrierPaid(escrowId, carrier, carrierPay);
        }
        if (!onTime) {
            uint256 penalty = (e.funded * latePenaltyBps) / 10_000;
            e.penaltyPaid = penalty;
            (address buyer, , , , , , , , , , ) = orders.orders(e.orderId);
            if (!paymentToken.transfer(buyer, penalty)) revert TransferFailed();
            emit PenaltyPaid(escrowId, penalty);
        }
    }

    /// @notice Refunds the unfunded remainder if the order is canceled.
    function refund(uint256 escrowId) external {
        Escrow storage e = escrows[escrowId];
        if (e.buyer == address(0)) revert UnknownEscrow(escrowId);
        if (e.settled) revert NothingToRelease(escrowId);
        ( , , , , , , , , , , SilsilaOrders.Status status) = orders.orders(e.orderId);
        if (status != SilsilaOrders.Status.Canceled) revert NothingToRelease(escrowId);
        uint256 remainder = e.funded - e.released;
        e.settled = true;
        if (remainder > 0) {
            if (!paymentToken.transfer(e.buyer, remainder)) revert TransferFailed();
        }
        emit Refunded(escrowId, remainder);
    }

    function shipmentOfOrder(uint256 orderId) internal view returns (uint256) {
        // shipmentOfOrder stores shipmentId + 1
        return SilsilaShipments(address(shipments)).shipmentOfOrder(orderId);
    }

    /* ==================== ADMIN ==================== */

    function setReleaseBps(uint8 milestone, uint256 bps) external onlyRole(OPERATOR_ROLE) {
        if (bps > 10_000) revert ZeroAmount();
        releaseBps[milestone] = bps;
        emit SplitSet(milestone, bps);
    }

    function setFees(uint256 platformBps, uint256 penaltyBps, uint256 carrierBps_) external onlyRole(OPERATOR_ROLE) {
        if (platformBps > 1000 || penaltyBps > 2000 || carrierBps_ > 2000) revert ZeroAmount();
        platformFeeBps = platformBps;
        latePenaltyBps = penaltyBps;
        carrierBps = carrierBps_;
        emit FeesSet(platformBps, penaltyBps, carrierBps_);
    }
}
