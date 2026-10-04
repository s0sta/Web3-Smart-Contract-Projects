// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {MockStable} from "../src/MockStable.sol";
import {SilsilaRegistry} from "../src/SilsilaRegistry.sol";
import {SilsilaCompliance} from "../src/SilsilaCompliance.sol";
import {SilsilaOrders} from "../src/SilsilaOrders.sol";
import {SilsilaShipments} from "../src/SilsilaShipments.sol";
import {SilsilaQuality} from "../src/SilsilaQuality.sol";
import {SilsilaPayments} from "../src/SilsilaPayments.sol";
import {SilsilaCargoInsurance} from "../src/SilsilaCargoInsurance.sol";
import {SilsilaReputation} from "../src/SilsilaReputation.sol";
import {SilsilaTreasury} from "../src/SilsilaTreasury.sol";
import {SilsilaOracle} from "../src/SilsilaOracle.sol";
import {SilsilaGovernor} from "../src/SilsilaGovernor.sol";

/// @notice The complete trade network: AED-S payments, a registry with buyer/
///         supplier/carrier/auditor entities, export-control compliance (UAE/US
///         allowed), purchase orders, shipment tracking, quality inspections,
///         milestone escrow payments (30% packing / 70% delivery, 0.5% fee,
///         3% carrier, 5% late penalty), cargo insurance (2% premium), the
///         reputation engine, the treasury, the EMA oracle and the governor.
abstract contract SilsilaFixture is Test {
    MockStable internal aeds;
    SilsilaRegistry internal registry;
    SilsilaCompliance internal compliance;
    SilsilaOrders internal orders;
    SilsilaShipments internal shipments;
    SilsilaQuality internal quality;
    SilsilaPayments internal payments;
    SilsilaCargoInsurance internal cargo;
    SilsilaReputation internal reputation;
    SilsilaTreasury internal treasury;
    SilsilaOracle internal oracle;
    SilsilaGovernor internal governor;

    address internal officer = address(0xC);
    address internal guardian = address(0x6);
    address internal buyer = address(0xA);
    address internal supplier = address(0xB);
    address internal carrier = address(0xD);
    address internal auditor = address(0xE);
    address internal adjuster1 = address(0xF1);
    address internal adjuster2 = address(0xF2);
    address internal outsider = address(0x99);

    uint64 internal REGION_UAE = 784;
    uint64 internal REGION_US = 840;

    uint256 internal orderId;
    uint256 internal shipmentId;

    function setUp() public virtual {
        aeds = new MockStable();
        registry = new SilsilaRegistry();
        compliance = new SilsilaCompliance(registry);
        orders = new SilsilaOrders(registry, compliance);
        shipments = new SilsilaShipments(registry, orders);
        quality = new SilsilaQuality(registry, shipments, orders);
        treasury = new SilsilaTreasury(aeds, 2000);
        payments = new SilsilaPayments(registry, orders, shipments, treasury, aeds);
        cargo = new SilsilaCargoInsurance(registry, orders, shipments, aeds);
        reputation = new SilsilaReputation(registry, shipments, quality);
        oracle = new SilsilaOracle(1 hours, 24 hours);
        governor = new SilsilaGovernor(registry, compliance, orders, shipments, quality, payments, cargo, reputation, treasury, oracle, 300);

        // wiring
        registry.grantRole(registry.OFFICER_ROLE(), officer);
        compliance.grantRole(compliance.OFFICER_ROLE(), officer);
        payments.grantRole(payments.OPERATOR_ROLE(), address(governor));
        cargo.grantRole(cargo.ADJUSTER_ROLE(), adjuster1);
        cargo.grantRole(cargo.ADJUSTER_ROLE(), adjuster2);
        governor.grantRole(governor.GUARDIAN_ROLE(), guardian);
        oracle.grantRole(oracle.GUARDIAN_ROLE(), guardian);

        // regions
        vm.prank(officer);
        compliance.setRegionAllowed(REGION_UAE, true);
        vm.prank(officer);
        compliance.setRegionAllowed(REGION_US, true);

        // entities
        vm.prank(buyer);
        registry.register(SilsilaRegistry.Role.Buyer, REGION_UAE);
        vm.prank(supplier);
        registry.register(SilsilaRegistry.Role.Supplier, REGION_UAE);
        vm.prank(carrier);
        registry.register(SilsilaRegistry.Role.Carrier, REGION_UAE);
        vm.prank(auditor);
        registry.register(SilsilaRegistry.Role.Auditor, REGION_UAE);
        vm.prank(adjuster1);
        registry.register(SilsilaRegistry.Role.Financier, REGION_UAE);

        // funds
        aeds.setMinter(address(this));
        aeds.mint(buyer, 1_000_000 ether);
        vm.prank(buyer);
        aeds.approve(address(payments), 1_000_000 ether);
        vm.prank(buyer);
        aeds.approve(address(cargo), 1_000_000 ether);
        aeds.mint(adjuster1, 100_000 ether);
        aeds.mint(address(cargo), 500_000 ether); // insurer capital

        // a live order + shipment flow is built per-test via helpers
        vm.prank(buyer);
        orderId = orders.createOrder(supplier, 100, 100 ether, uint64(block.timestamp + 30 days), REGION_UAE, bytes32("item"), false, bytes32(0));
        vm.prank(supplier);
        orders.accept(orderId);
        vm.prank(buyer);
        shipmentId = shipments.createShipment(orderId, carrier);
    }

    function _advance(SilsilaShipments.Milestone m) internal {
        vm.prank(carrier);
        shipments.updateMilestone(shipmentId, m, bytes32("loc"));
    }

    function _deliver(bool onTime) internal {
        _advance(SilsilaShipments.Milestone.Packed);
        _advance(SilsilaShipments.Milestone.InTransit);
        _advance(SilsilaShipments.Milestone.Customs);
        if (!onTime) vm.warp(block.timestamp + 31 days);
        vm.prank(carrier);
        shipments.deliver(shipmentId, bytes32("pod"));
    }
}
