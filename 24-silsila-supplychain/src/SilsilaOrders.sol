// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {SilsilaRegistry} from "./SilsilaRegistry.sol";
import {SilsilaCompliance} from "./SilsilaCompliance.sol";

/// @title SilsilaOrders
/// @notice The purchase-order desk: buyers issue orders (item, quantity, unit
///         price, deadline, destination region), suppliers accept or reject,
///         fulfill partially, and either side can cancel while open.
contract SilsilaOrders is AccessControl {
    /// @notice Order states.
    enum Status { Open, Accepted, PartiallyFulfilled, Fulfilled, Canceled, Rejected }

    /// @notice One purchase order.
    struct Order {
        address buyer;
        address supplier;
        uint256 quantity;
        uint256 fulfilled;
        uint256 unitPrice;
        uint64 deadline;
        uint64 destinationRegion;
        bytes32 itemHash;
        bool crossBorder;
        bytes32 exportDocsHash;
        Status status;
    }

    Order[] public orders;
    mapping(address buyer => uint256[]) public ordersOfBuyer;
    mapping(address supplier => uint256[]) public ordersOfSupplier;

    SilsilaRegistry public immutable registry;
    SilsilaCompliance public immutable compliance;

    event OrderCreated(uint256 indexed orderId, address indexed buyer, address indexed supplier, uint256 quantity, uint256 unitPrice);
    event OrderAccepted(uint256 indexed orderId);
    event OrderFulfilled(uint256 indexed orderId, uint256 quantity);
    event OrderCanceled(uint256 indexed orderId);
    event OrderRejected(uint256 indexed orderId);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownOrder(uint256 orderId);
    error InvalidState(uint256 orderId, Status expected, Status actual);
    error NotParty(uint256 orderId);
    error DeadlinePassed(uint256 orderId, uint256 deadline);
    error OverFulfillment(uint256 orderId, uint256 quantity, uint256 remaining);

    constructor(SilsilaRegistry registry_, SilsilaCompliance compliance_) {
        if (address(registry_) == address(0) || address(compliance_) == address(0)) revert ZeroAddress();
        registry = registry_;
        compliance = compliance_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /* ==================== LIFECYCLE ==================== */

    function createOrder(
        address supplier,
        uint256 quantity,
        uint256 unitPrice,
        uint64 deadline,
        uint64 destinationRegion,
        bytes32 itemHash,
        bool crossBorder,
        bytes32 exportDocsHash
    ) external returns (uint256 orderId) {
        if (supplier == address(0) || quantity == 0 || unitPrice == 0) revert ZeroAmount();
        if (deadline <= block.timestamp) revert DeadlinePassed(0, deadline);
        compliance.requireRole(msg.sender, SilsilaRegistry.Role.Buyer);
        compliance.requireRole(supplier, SilsilaRegistry.Role.Supplier);
        compliance.validateRoute(msg.sender, supplier, destinationRegion, crossBorder, exportDocsHash);

        orderId = orders.length;
        orders.push();
        Order storage o = orders[orderId];
        o.buyer = msg.sender;
        o.supplier = supplier;
        o.quantity = quantity;
        o.unitPrice = unitPrice;
        o.deadline = deadline;
        o.destinationRegion = destinationRegion;
        o.itemHash = itemHash;
        o.crossBorder = crossBorder;
        o.exportDocsHash = exportDocsHash;
        o.status = Status.Open;
        ordersOfBuyer[msg.sender].push(orderId);
        ordersOfSupplier[supplier].push(orderId);
        emit OrderCreated(orderId, msg.sender, supplier, quantity, unitPrice);
    }

    function accept(uint256 orderId) external {
        Order storage o = orders[orderId];
        if (o.buyer == address(0)) revert UnknownOrder(orderId);
        if (msg.sender != o.supplier) revert NotParty(orderId);
        if (o.status != Status.Open) revert InvalidState(orderId, Status.Open, o.status);
        if (block.timestamp > o.deadline) revert DeadlinePassed(orderId, o.deadline);
        o.status = Status.Accepted;
        emit OrderAccepted(orderId);
    }

    /// @notice The buyer records a received quantity (partial or full).
    function fulfill(uint256 orderId, uint256 quantity) external {
        Order storage o = orders[orderId];
        if (o.buyer == address(0)) revert UnknownOrder(orderId);
        if (msg.sender != o.buyer) revert NotParty(orderId);
        if (o.status == Status.Canceled || o.status == Status.Rejected || o.status == Status.Fulfilled) {
            revert InvalidState(orderId, Status.Accepted, o.status);
        }
        if (quantity == 0) revert ZeroAmount();
        uint256 remaining = o.quantity - o.fulfilled;
        if (quantity > remaining) revert OverFulfillment(orderId, quantity, remaining);
        o.fulfilled += quantity;
        o.status = o.fulfilled == o.quantity ? Status.Fulfilled : Status.PartiallyFulfilled;
        emit OrderFulfilled(orderId, quantity);
    }

    function cancel(uint256 orderId) external {
        Order storage o = orders[orderId];
        if (o.buyer == address(0)) revert UnknownOrder(orderId);
        if (msg.sender != o.buyer && msg.sender != o.supplier) revert NotParty(orderId);
        if (o.status == Status.Fulfilled || o.status == Status.Canceled) {
            revert InvalidState(orderId, Status.Open, o.status);
        }
        o.status = Status.Canceled;
        emit OrderCanceled(orderId);
    }

    function reject(uint256 orderId) external {
        Order storage o = orders[orderId];
        if (msg.sender != o.supplier) revert NotParty(orderId);
        if (o.status != Status.Open) revert InvalidState(orderId, Status.Open, o.status);
        o.status = Status.Rejected;
        emit OrderRejected(orderId);
    }

    function totalValue(uint256 orderId) external view returns (uint256) {
        Order storage o = orders[orderId];
        return o.quantity * o.unitPrice;
    }

    function ordersOfBuyerList(address buyer) external view returns (uint256[] memory) {
        return ordersOfBuyer[buyer];
    }

    function ordersOfSupplierList(address supplier) external view returns (uint256[] memory) {
        return ordersOfSupplier[supplier];
    }
}
