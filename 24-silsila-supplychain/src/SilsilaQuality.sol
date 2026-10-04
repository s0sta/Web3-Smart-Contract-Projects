// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {SilsilaRegistry} from "./SilsilaRegistry.sol";
import {SilsilaShipments} from "./SilsilaShipments.sol";
import {SilsilaOrders} from "./SilsilaOrders.sol";

/// @title SilsilaQuality
/// @notice The inspection desk: auditors grade delivered shipments (0–100) with
///         an evidence hash; the supplier can dispute a grade; the auditor's
///         final ruling stands and feeds the reputation engine.
contract SilsilaQuality is AccessControl {
    /// @notice One inspection report.
    struct Inspection {
        uint256 shipmentId;
        address auditor;
        uint8 grade; // 0–100
        bytes32 evidenceHash;
        uint64 inspectedAt;
        bool disputed;
        uint8 finalGrade;
        bool resolved;
    }

    Inspection[] public inspections;
    mapping(uint256 shipmentId => uint256) public inspectionOfShipment;

    SilsilaRegistry public immutable registry;
    SilsilaShipments public immutable shipments;
    SilsilaOrders public immutable orders;

    event InspectionSubmitted(uint256 indexed inspectionId, uint256 shipmentId, address indexed auditor, uint8 grade);
    event InspectionDisputed(uint256 indexed inspectionId);
    event InspectionResolved(uint256 indexed inspectionId, uint8 finalGrade);

    error ZeroAddress();
    error UnknownInspection(uint256 inspectionId);
    error NotAuditor();
    error NotDelivered(uint256 shipmentId);
    error AlreadyInspected(uint256 shipmentId);
    error InvalidGrade();
    error AlreadyResolved(uint256 inspectionId);
    error NotSupplier(uint256 shipmentId);

    constructor(SilsilaRegistry registry_, SilsilaShipments shipments_, SilsilaOrders orders_) {
        if (address(registry_) == address(0) || address(shipments_) == address(0) || address(orders_) == address(0)) revert ZeroAddress();
        registry = registry_;
        shipments = shipments_;
        orders = orders_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /* ==================== INSPECTIONS ==================== */

    function inspect(uint256 shipmentId, uint8 grade, bytes32 evidenceHash) external returns (uint256 inspectionId) {
        if (registry.roleOf(msg.sender) != SilsilaRegistry.Role.Auditor) revert NotAuditor();
        if (shipments.milestoneOf(shipmentId) != SilsilaShipments.Milestone.Delivered) revert NotDelivered(shipmentId);
        if (inspectionOfShipment[shipmentId] != 0) revert AlreadyInspected(shipmentId);
        if (grade > 100) revert InvalidGrade();

        inspectionId = inspections.length;
        inspections.push();
        Inspection storage i = inspections[inspectionId];
        i.shipmentId = shipmentId;
        i.auditor = msg.sender;
        i.grade = grade;
        i.evidenceHash = evidenceHash;
        i.inspectedAt = uint64(block.timestamp);
        i.finalGrade = grade;
        i.resolved = true;
        inspectionOfShipment[shipmentId] = inspectionId + 1;
        emit InspectionSubmitted(inspectionId, shipmentId, msg.sender, grade);
    }

    /* ==================== DISPUTES ==================== */

    function dispute(uint256 inspectionId) external {
        Inspection storage i = inspections[inspectionId];
        if (i.auditor == address(0)) revert UnknownInspection(inspectionId);
        if (i.disputed) revert AlreadyResolved(inspectionId);
        // only the supplier of the underlying order may dispute
        (uint256 orderId, , , , , , , ) = shipments.shipments(i.shipmentId);
        ( , address supplier, , , , , , , , , ) = orders.orders(orderId);
        if (msg.sender != supplier) revert NotSupplier(i.shipmentId);
        i.disputed = true;
        i.resolved = false;
        emit InspectionDisputed(inspectionId);
    }

    /// @notice The auditor re-rules on a disputed inspection.
    function resolve(uint256 inspectionId, uint8 finalGrade) external {
        Inspection storage i = inspections[inspectionId];
        if (i.auditor == address(0)) revert UnknownInspection(inspectionId);
        if (msg.sender != i.auditor) revert NotAuditor();
        if (!i.disputed) revert AlreadyResolved(inspectionId);
        if (finalGrade > 100) revert InvalidGrade();
        i.finalGrade = finalGrade;
        i.resolved = true;
        emit InspectionResolved(inspectionId, finalGrade);
    }

}
