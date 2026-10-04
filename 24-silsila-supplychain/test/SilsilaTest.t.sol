// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {SilsilaFixture} from "./SilsilaFixture.sol";
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

contract SilsilaRegistryTest is SilsilaFixture {
    function test_Register_SetsRole() public {
        assertEq(uint8(registry.roleOf(buyer)), uint8(SilsilaRegistry.Role.Buyer));
        assertEq(registry.entityCount(), 5);
    }

    function test_Freeze_OfficerOnly() public {
        vm.prank(outsider);
        vm.expectRevert(SilsilaRegistry.NotOfficer.selector);
        registry.setFrozen(buyer, true);
        vm.prank(officer);
        registry.setFrozen(buyer, true);
        assertFalse(registry.isActive(buyer));
    }

    function test_DoubleRegister_Reverts() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(SilsilaRegistry.AlreadyRegistered.selector, buyer));
        registry.register(SilsilaRegistry.Role.Supplier, REGION_UAE);
    }
}

contract SilsilaComplianceTest is SilsilaFixture {
    function test_RegionBlocked() public {
        vm.expectRevert(abi.encodeWithSelector(SilsilaCompliance.RegionBlocked.selector, uint64(999)));
        compliance.validateRoute(buyer, supplier, 999, false, bytes32(0));
    }

    function test_ExportDocs_Required() public {
        vm.expectRevert(SilsilaCompliance.MissingExportDocs.selector);
        compliance.validateRoute(buyer, supplier, REGION_US, true, bytes32(0));
        compliance.validateRoute(buyer, supplier, REGION_US, true, bytes32("bill-of-lading"));
    }

    function test_WrongRole() public {
        vm.expectRevert(abi.encodeWithSelector(SilsilaCompliance.WrongRole.selector, supplier, SilsilaRegistry.Role.Buyer));
        compliance.requireRole(supplier, SilsilaRegistry.Role.Buyer);
    }
}

contract SilsilaOrdersTest is SilsilaFixture {
    function test_Create_RequiresRoles() public {
        vm.prank(outsider);
        vm.expectRevert();
        orders.createOrder(supplier, 10, 1 ether, uint64(block.timestamp + 10 days), REGION_UAE, bytes32("x"), false, bytes32(0));
    }

    function test_Accept_SupplierOnly() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(SilsilaOrders.NotParty.selector, orderId));
        orders.accept(orderId);
    }

    function test_Fulfill_PartialThenFull() public {
        vm.prank(buyer);
        orders.fulfill(orderId, 40);
        ( , , , uint256 fulfilled, , , , , , , SilsilaOrders.Status status) = orders.orders(orderId);
        assertEq(fulfilled, 40);
        assertEq(uint8(status), uint8(SilsilaOrders.Status.PartiallyFulfilled));
        vm.prank(buyer);
        orders.fulfill(orderId, 60);
        ( , , , uint256 f2, , , , , , , SilsilaOrders.Status st2) = orders.orders(orderId);
        assertEq(f2, 100);
        assertEq(uint8(st2), uint8(SilsilaOrders.Status.Fulfilled));
    }

    function test_Fulfill_OverReverts() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(SilsilaOrders.OverFulfillment.selector, orderId, 150, 100));
        orders.fulfill(orderId, 150);
    }

    function test_Cancel_ByBuyer() public {
        vm.prank(buyer);
        orders.cancel(orderId);
        ( , , , , , , , , , , SilsilaOrders.Status status) = orders.orders(orderId);
        assertEq(uint8(status), uint8(SilsilaOrders.Status.Canceled));
    }

    function test_Accept_Deadline() public {
        vm.warp(block.timestamp + 31 days);
        vm.prank(supplier);
        vm.expectRevert();
        orders.accept(orderId);
    }
}

contract SilsilaShipmentsTest is SilsilaFixture {
    function test_Milestones_Ordered() public {
        vm.prank(carrier);
        vm.expectRevert();
        shipments.updateMilestone(shipmentId, SilsilaShipments.Milestone.Customs, bytes32("x")); // skips Packed
        _advance(SilsilaShipments.Milestone.Packed);
        assertEq(uint8(shipments.milestoneOf(shipmentId)), uint8(SilsilaShipments.Milestone.Packed));
    }

    function test_Update_OnlyCarrierOrAuditor() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(SilsilaShipments.NotCarrierOrAuditor.selector, shipmentId));
        shipments.updateMilestone(shipmentId, SilsilaShipments.Milestone.Packed, bytes32("x"));
    }

    function test_Deliver_RequiresPod() public {
        _advance(SilsilaShipments.Milestone.Packed);
        _advance(SilsilaShipments.Milestone.InTransit);
        _advance(SilsilaShipments.Milestone.Customs);
        vm.prank(carrier);
        vm.expectRevert(abi.encodeWithSelector(SilsilaShipments.MissingPod.selector, shipmentId));
        shipments.deliver(shipmentId, bytes32(0));
    }

    function test_Deliver_OnTime() public {
        _deliver(true);
        ( , , , , , bool onTime, , ) = shipments.shipments(shipmentId);
        assertTrue(onTime);
    }

    function test_Deliver_Late() public {
        _deliver(false);
        ( , , , , , bool onTime, , ) = shipments.shipments(shipmentId);
        assertFalse(onTime);
    }

    function test_OneShipmentPerOrder() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(SilsilaShipments.AlreadyShipped.selector, orderId));
        shipments.createShipment(orderId, carrier);
    }
}

contract SilsilaQualityTest is SilsilaFixture {
    function test_Inspect_AuditorOnly() public {
        vm.prank(outsider);
        vm.expectRevert(SilsilaQuality.NotAuditor.selector);
        quality.inspect(shipmentId, 90, bytes32("x"));
    }

    function test_Inspect_RequiresDelivery() public {
        vm.prank(auditor);
        vm.expectRevert(abi.encodeWithSelector(SilsilaQuality.NotDelivered.selector, shipmentId));
        quality.inspect(shipmentId, 90, bytes32("x"));
    }

    function test_Inspect_AfterDelivery() public {
        _deliver(true);
        vm.prank(auditor);
        uint256 id = quality.inspect(shipmentId, 90, bytes32("evidence"));
        ( , , uint8 grade, , , , uint8 finalGrade, bool resolved) = quality.inspections(id);
        assertEq(grade, 90);
        assertEq(finalGrade, 90);
        assertTrue(resolved);
    }

    function test_Dispute_SupplierOnly() public {
        _deliver(true);
        vm.prank(auditor);
        uint256 id = quality.inspect(shipmentId, 90, bytes32("evidence"));
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(SilsilaQuality.NotSupplier.selector, shipmentId));
        quality.dispute(id);
        vm.prank(supplier);
        quality.dispute(id);
        ( , , , , , bool disputed, , ) = quality.inspections(id);
        assertTrue(disputed);
    }
}

contract SilsilaPaymentsTest is SilsilaFixture {
    function _fund() internal returns (uint256) {
        vm.prank(buyer);
        return payments.fund(orderId, 10_000 ether); // 100 × 100
    }

    function test_Fund_EscrowsFullValue() public {
        uint256 id = _fund();
        ( , , uint256 funded, , , , ) = payments.escrows(id);
        assertEq(funded, 10_000 ether);
        assertEq(aeds.balanceOf(address(payments)), 10_000 ether);
    }

    function test_Release_PackingThirtyPercent() public {
        uint256 id = _fund();
        _advance(SilsilaShipments.Milestone.Packed);
        uint256 before = aeds.balanceOf(supplier);
        payments.release(id, uint8(SilsilaShipments.Milestone.Packed));
        // 30% of 10,000 = 3,000 − 0.5% fee = 2,985
        assertEq(aeds.balanceOf(supplier) - before, 2_985 ether);
        assertEq(treasury.totalFeesCollected(), 15 ether);
    }

    function test_Release_BeforeMilestoneReverts() public {
        uint256 id = _fund();
        vm.expectRevert(abi.encodeWithSelector(SilsilaPayments.NotDelivered.selector, id));
        payments.release(id, uint8(SilsilaShipments.Milestone.Delivered));
    }

    function test_Delivery_PaysCarrierAndSettles() public {
        uint256 id = _fund();
        _deliver(true);
        uint256 beforeSupplier = aeds.balanceOf(supplier);
        uint256 beforeCarrier = aeds.balanceOf(carrier);
        payments.release(id, uint8(SilsilaShipments.Milestone.Delivered));
        // 70% of 10,000 = 7,000 − 35 fee = 6,965 to the supplier; 300 to the carrier
        assertEq(aeds.balanceOf(supplier) - beforeSupplier, 6_965 ether);
        assertEq(aeds.balanceOf(carrier) - beforeCarrier, 300 ether);
    }

    function test_LateDelivery_PenaltyToBuyer() public {
        uint256 id = _fund();
        _deliver(false);
        uint256 before = aeds.balanceOf(buyer);
        payments.release(id, uint8(SilsilaShipments.Milestone.Delivered));
        assertEq(aeds.balanceOf(buyer) - before, 500 ether); // 5% penalty
    }

    function test_Refund_OnCancel() public {
        uint256 id = _fund();
        vm.prank(buyer);
        orders.cancel(orderId);
        uint256 before = aeds.balanceOf(buyer);
        payments.refund(id);
        assertEq(aeds.balanceOf(buyer) - before, 10_000 ether);
    }
}

contract SilsilaCargoInsuranceTest is SilsilaFixture {
    function test_Insure_BuyerOnly() public {
        vm.prank(outsider);
        vm.expectRevert(SilsilaCargoInsurance.NotAdjuster.selector);
        cargo.insure(shipmentId, 10_000 ether);
    }

    function test_Insure_Premium() public {
        vm.prank(buyer);
        uint256 id = cargo.insure(shipmentId, 10_000 ether);
        ( , , uint256 cover, uint256 premium, ) = cargo.policies(id);
        assertEq(cover, 10_000 ether);
        assertEq(premium, 200 ether); // 2%
        assertEq(aeds.balanceOf(address(cargo)), 500_000 ether + 200 ether); // capital + premium
    }

    function test_Claim_TwoAdjustersApprove() public {
        vm.prank(buyer);
        uint256 pid = cargo.insure(shipmentId, 10_000 ether);
        vm.prank(buyer);
        uint256 cid = cargo.fileClaim(pid, 5_000 ether, "cargo damaged in transit");
        vm.prank(adjuster1);
        cargo.voteClaim(cid, true);
        uint256 before = aeds.balanceOf(buyer);
        vm.prank(adjuster2);
        cargo.voteClaim(cid, true);
        assertEq(aeds.balanceOf(buyer) - before, 5_000 ether);
    }

    function test_Claim_OverCoverReverts() public {
        vm.prank(buyer);
        uint256 pid = cargo.insure(shipmentId, 10_000 ether);
        vm.prank(buyer);
        vm.expectRevert(SilsilaCargoInsurance.ZeroAmount.selector);
        cargo.fileClaim(pid, 20_000 ether, "over");
    }

    function test_Vote_AdjusterOnly() public {
        vm.prank(buyer);
        uint256 pid = cargo.insure(shipmentId, 10_000 ether);
        vm.prank(buyer);
        uint256 cid = cargo.fileClaim(pid, 1_000 ether, "x");
        vm.prank(outsider);
        vm.expectRevert();
        cargo.voteClaim(cid, true);
    }
}

contract SilsilaReputationTest is SilsilaFixture {
    function test_Initial_Neutral() public {
        assertEq(reputation.scoreOf(carrier), 500);
    }

    function test_OnTimeDelivery_RaisesScore() public {
        reputation.recordDelivery(carrier, true);
        assertTrue(reputation.scoreOf(carrier) > 500);
    }

    function test_LateDelivery_LowersScore() public {
        reputation.recordDelivery(carrier, false);
        assertTrue(reputation.scoreOf(carrier) < 500);
    }

    function test_Grade_RaisesSupplierScore() public {
        reputation.recordGrade(supplier, 90);
        assertTrue(reputation.scoreOf(supplier) > 500);
    }

    function test_Checkpoint_Snapshot() public {
        reputation.recordDelivery(carrier, true);
        vm.roll(block.number + 1);
        reputation.checkpoint(carrier);
        assertEq(reputation.getPastScore(carrier, block.number), reputation.scoreOf(carrier));
    }
}

contract SilsilaGovernorTest is SilsilaFixture {
    function test_Propose_ReputationWeighted() public {
        reputation.recordDelivery(carrier, true);
        reputation.checkpoint(carrier);
        uint256 weight = reputation.scoreOf(carrier);
        vm.prank(carrier);
        uint256 id = governor.propose(address(payments), 0, abi.encodeCall(payments.setFees, (60, 500, 300)), "raise platform fee");
        vm.warp(block.timestamp + 3 days);
        vm.prank(carrier);
        governor.vote(id, true);
        ( , , , , , uint256 forV, , , , , , , ) = governor.proposals(id);
        assertEq(forV, weight);
    }

    function test_FullLifecycle_ChangesFees() public {
        reputation.recordDelivery(carrier, true);
        reputation.checkpoint(carrier);
        vm.prank(carrier);
        uint256 id = governor.propose(address(payments), 0, abi.encodeCall(payments.setFees, (60, 500, 300)), "raise fee");
        vm.warp(block.timestamp + 3 days);
        vm.prank(carrier);
        governor.vote(id, true);
        vm.warp(block.timestamp + 10 days);
        assertEq(governor.state(id), 3);
        governor.execute(id);
        assertEq(governor.state(id), 4);
        assertEq(payments.platformFeeBps(), 60);
    }

    function test_InvalidTarget_Rejected() public {
        vm.expectRevert(SilsilaGovernor.InvalidTargets.selector);
        governor.propose(address(0xDEAD), 0, hex"1234", "escape");
    }

    function test_Timelock_BlocksEarly() public {
        reputation.recordDelivery(carrier, true);
        reputation.checkpoint(carrier);
        vm.prank(carrier);
        uint256 id = governor.propose(address(payments), 0, abi.encodeCall(payments.setFees, (60, 500, 300)), "timelocked");
        vm.warp(block.timestamp + 3 days);
        vm.prank(carrier);
        governor.vote(id, true);
        vm.warp(block.timestamp + 5 days);
        vm.expectRevert();
        governor.execute(id);
        assertEq(governor.state(id), 2);
    }

    function test_Pause_GuardianOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        governor.pause();
        vm.prank(guardian);
        governor.pause();
        vm.expectRevert(SilsilaGovernor.ProtocolPaused.selector);
        governor.propose(address(payments), 0, hex"1234", "paused");
    }
}
