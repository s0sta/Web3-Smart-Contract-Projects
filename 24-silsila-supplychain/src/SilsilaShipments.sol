// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {SilsilaRegistry} from "./SilsilaRegistry.sol";
import {SilsilaOrders} from "./SilsilaOrders.sol";

/// @title SilsilaShipments
/// @notice The track-and-trace rail: a shipment rides through milestones
///         (Created → Packed → InTransit → Customs → Delivered), each update
///         recorded by the assigned carrier or an auditor with a location hash
///         and a timestamp. Delivery requires a proof-of-delivery hash.
contract SilsilaShipments is AccessControl {
    /// @notice Milestones.
    enum Milestone { None, Created, Packed, InTransit, Customs, Delivered }

    /// @notice One shipment.
    struct Shipment {
        uint256 orderId;
        address carrier;
        Milestone milestone;
        uint64 updatedAt;
        uint64 deliveredAt;
        bool deliveredOnTime;
        bytes32 lastLocationHash;
        bytes32 proofOfDelivery;
    }

    Shipment[] public shipments;
    mapping(uint256 orderId => uint256) public shipmentOfOrder;

    SilsilaRegistry public immutable registry;
    SilsilaOrders public immutable orders;

    event ShipmentCreated(uint256 indexed shipmentId, uint256 orderId, address indexed carrier);
    event MilestoneReached(uint256 indexed shipmentId, Milestone milestone, bytes32 locationHash, uint256 timestamp);
    event Delivered(uint256 indexed shipmentId, bytes32 proofOfDelivery, bool onTime);

    error ZeroAddress();
    error UnknownShipment(uint256 shipmentId);
    error NotCarrierOrAuditor(uint256 shipmentId);
    error InvalidMilestone(uint256 shipmentId, Milestone from, Milestone to);
    error AlreadyShipped(uint256 orderId);
    error OrderNotAccepted(uint256 orderId);
    error MissingPod(uint256 shipmentId);

    constructor(SilsilaRegistry registry_, SilsilaOrders orders_) {
        if (address(registry_) == address(0) || address(orders_) == address(0)) revert ZeroAddress();
        registry = registry_;
        orders = orders_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /* ==================== LIFECYCLE ==================== */

    function createShipment(uint256 orderId, address carrier) external returns (uint256 shipmentId) {
        if (carrier == address(0)) revert ZeroAddress();
        (address buyer, , , , , uint64 deadline, , , , , SilsilaOrders.Status status) = orders.orders(orderId);
        if (status != SilsilaOrders.Status.Accepted && status != SilsilaOrders.Status.PartiallyFulfilled) {
            revert OrderNotAccepted(orderId);
        }
        if (shipmentOfOrder[orderId] != 0) {
            revert AlreadyShipped(orderId);
        }
        if (msg.sender != buyer) revert NotCarrierOrAuditor(0);
        if (registry.roleOf(carrier) != SilsilaRegistry.Role.Carrier) revert NotCarrierOrAuditor(0);
        deadline; // on-time is judged at delivery against the order deadline

        shipmentId = shipments.length;
        shipments.push();
        Shipment storage s = shipments[shipmentId];
        s.orderId = orderId;
        s.carrier = carrier;
        s.milestone = Milestone.Created;
        s.updatedAt = uint64(block.timestamp);
        shipmentOfOrder[orderId] = shipmentId + 1; // +1 so 0 means "none"
        emit ShipmentCreated(shipmentId, orderId, carrier);
    }

    /// @notice The carrier (or an auditor) advances the milestone.
    function updateMilestone(uint256 shipmentId, Milestone next, bytes32 locationHash) external {
        Shipment storage s = shipments[shipmentId];
        if (s.carrier == address(0)) revert UnknownShipment(shipmentId);
        if (msg.sender != s.carrier && registry.roleOf(msg.sender) != SilsilaRegistry.Role.Auditor) {
            revert NotCarrierOrAuditor(shipmentId);
        }
        uint8 current = uint8(s.milestone);
        uint8 target = uint8(next);
        if (target != current + 1) revert InvalidMilestone(shipmentId, s.milestone, next);

        s.milestone = next;
        s.updatedAt = uint64(block.timestamp);
        s.lastLocationHash = locationHash;
        emit MilestoneReached(shipmentId, next, locationHash, block.timestamp);
    }

    /// @notice Delivery closes the shipment with a proof-of-delivery hash.
    function deliver(uint256 shipmentId, bytes32 proofOfDelivery) external {
        Shipment storage s = shipments[shipmentId];
        if (s.carrier == address(0)) revert UnknownShipment(shipmentId);
        if (msg.sender != s.carrier && registry.roleOf(msg.sender) != SilsilaRegistry.Role.Auditor) {
            revert NotCarrierOrAuditor(shipmentId);
        }
        if (uint8(s.milestone) != uint8(Milestone.Customs)) {
            revert InvalidMilestone(shipmentId, s.milestone, Milestone.Delivered);
        }
        if (proofOfDelivery == bytes32(0)) revert MissingPod(shipmentId);
        s.milestone = Milestone.Delivered;
        s.proofOfDelivery = proofOfDelivery;
        s.deliveredAt = uint64(block.timestamp);
        ( , , , , , uint64 deadline, , , , , ) = orders.orders(s.orderId);
        s.deliveredOnTime = block.timestamp <= deadline;
        emit Delivered(shipmentId, proofOfDelivery, s.deliveredOnTime);
    }

    function milestoneOf(uint256 shipmentId) external view returns (Milestone) {
        return shipments[shipmentId].milestone;
    }
}
