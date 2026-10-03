// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {ZakatFixture} from "./ZakatFixture.sol";
import {AsnafRegistry} from "../src/AsnafRegistry.sol";
import {ZakatEngine} from "../src/ZakatEngine.sol";

contract AsnafRegistryTest is ZakatFixture {
    function test_Allocations_Bounded() public {
        assertEq(registry.totalAllocation(), 10_000);
        vm.expectRevert(AsnafRegistry.AllocationOverflow.selector);
        registry.setAllocation(0, 5000); // 5000 + 4000 + 1000 + 1000 > 10,000
    }

    function test_Allocations_CommitteeOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        registry.setAllocation(0, 3000);
    }

    function test_RegisterRecipient_CommitteeOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        registry.registerRecipient(address(0x3), 5, bytes32("p"));

        vm.prank(committee1);
        uint256 id = registry.registerRecipient(address(0x3), 5, bytes32("p"));
        (address acct, uint8 asnaf, , bool active) = registry.recipients(id);
        assertEq(acct, address(0x3));
        assertEq(asnaf, 5);
        assertTrue(active);
    }

    function test_RegisterRecipient_InvalidAsnaf() public {
        vm.expectRevert(AsnafRegistry.InvalidAsnaf.selector);
        registry.registerRecipient(address(0x3), 8, bytes32("p"));
    }

    function test_RegisterRecipient_RequiresProof() public {
        vm.expectRevert(AsnafRegistry.InvalidProof.selector);
        registry.registerRecipient(address(0x3), 0, bytes32(0));
    }

    function test_Deactivate_RemovesFromList() public {
        vm.prank(committee1);
        registry.deactivateRecipient(recipientId1);
        uint256[] memory ids = registry.recipientsOf(0);
        assertEq(ids.length, 0);
        assertEq(registry.recipientsOf(1).length, 1);
    }

    function test_AsnafNames() public {
        assertEq(registry.asnafName(0), "Fuqara (the poor)");
        assertEq(registry.asnafName(7), "Ibn Sabil (the stranded traveler)");
    }
}

contract ZakatEngineTest is ZakatFixture {
    /* ---------- nisab & hawl ---------- */

    function test_ZakatDue_RequiresHawl() public {
        // 100,000 declared ≥ nisab 4,000, but the hawl has not passed
        assertEq(engine.zakatDue(payer), 0);
        vm.warp(block.timestamp + 354 days + 1);
        assertEq(engine.zakatDue(payer), 2_500 ether); // 2.5% of 100,000
    }

    function test_HawlResetsBelowNisab() public {
        vm.warp(block.timestamp + 100 days);
        vm.prank(payer);
        engine.declareWealth(3_000 ether); // below nisab → clock resets
        vm.warp(block.timestamp + 354 days); // a full hawl from the reset
        assertEq(engine.zakatDue(payer), 0); // below nisab anyway
        vm.prank(payer);
        engine.declareWealth(10_000 ether); // back above → new clock
        vm.warp(block.timestamp + 354 days + 1);
        assertEq(engine.zakatDue(payer), 250 ether);
    }

    function test_PayZakat_RingFencesFund() public {
        vm.warp(block.timestamp + 354 days + 1);
        vm.prank(payer);
        uint256 due = engine.payZakat();
        assertEq(due, 2_500 ether);
        assertEq(engine.zakatFund(), 2_500 ether);
        assertEq(stable.balanceOf(address(engine)), 2_500 ether);
        assertEq(engine.totalCollected(), 2_500 ether);
    }

    function test_PayZakat_NothingDueReverts() public {
        vm.prank(payer);
        vm.expectRevert(ZakatEngine.NothingDue.selector);
        engine.payZakat();
    }

    function test_WealthSnapshots() public {
        vm.roll(block.number + 1);
        vm.prank(payer);
        engine.declareWealth(150_000 ether);
        assertEq(engine.getPastWealth(payer, block.number), 150_000 ether);
        assertEq(engine.getPastWealth(payer, block.number - 1), 100_000 ether);
    }

    /* ---------- disbursements ---------- */

    function _fundZakat() internal {
        vm.warp(block.timestamp + 354 days + 1);
        vm.prank(payer);
        engine.payZakat();
    }

    function test_Disbursement_TwoOfThreeApprovals() public {
        _fundZakat();
        uint256 id = engine.proposeDisbursement(recipientId1, 1_000 ether);

        vm.prank(committee1);
        engine.voteDisbursement(id, true);
        assertEq(stable.balanceOf(recipient1), 0); // one approval not enough

        vm.prank(committee2);
        engine.voteDisbursement(id, true);
        assertEq(stable.balanceOf(recipient1), 1_000 ether);
        assertEq(engine.zakatFund(), 1_500 ether);
    }

    function test_Disbursement_CommitteeOnly() public {
        _fundZakat();
        vm.prank(outsider);
        vm.expectRevert();
        engine.proposeDisbursement(recipientId1, 100 ether);
    }

    function test_Disbursement_UnknownRecipient() public {
        vm.expectRevert();
        engine.proposeDisbursement(99, 100 ether);
    }

    function test_Disbursement_InactiveRecipient() public {
        vm.prank(committee1);
        registry.deactivateRecipient(recipientId1);
        vm.expectRevert(abi.encodeWithSelector(ZakatEngine.RecipientNotActive.selector, recipientId1));
        engine.proposeDisbursement(recipientId1, 100 ether);
    }

    function test_Disbursement_ExceedsFund() public {
        _fundZakat();
        vm.expectRevert(abi.encodeWithSelector(ZakatEngine.InsufficientZakatFund.selector, 2_500 ether, 3_000 ether));
        engine.proposeDisbursement(recipientId1, 3_000 ether);
    }

    function test_Disbursement_CannotDoubleVote() public {
        _fundZakat();
        uint256 id = engine.proposeDisbursement(recipientId1, 100 ether);
        vm.prank(committee1);
        engine.voteDisbursement(id, true);
        vm.prank(committee1);
        vm.expectRevert(abi.encodeWithSelector(ZakatEngine.AlreadyVoted.selector, id, committee1));
        engine.voteDisbursement(id, true);
    }

    function test_Disbursement_Records() public {
        _fundZakat();
        uint256 id = engine.proposeDisbursement(recipientId2, 500 ether);
        vm.prank(committee1);
        engine.voteDisbursement(id, true);
        vm.prank(committee2);
        engine.voteDisbursement(id, true);
        (uint256 rid, uint8 asnaf, uint256 amount, , uint256 approvals, bool executed) = engine.disbursements(id);
        assertEq(rid, recipientId2);
        assertEq(asnaf, 1);
        assertEq(amount, 500 ether);
        assertEq(approvals, 2);
        assertTrue(executed);
        assertEq(engine.totalDistributed(), 500 ether);
    }

    /* ---------- nisab & pause ---------- */

    function test_SetNisab_CommitteeOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        engine.setNisab(5_000 ether);
        vm.prank(committee1);
        engine.setNisab(5_000 ether);
        assertEq(engine.nisab(), 5_000 ether);
    }

    function test_Pause_GuardianOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        engine.pause();

        vm.prank(guardian);
        engine.pause();
        vm.prank(payer);
        vm.expectRevert(ZakatEngine.ProtocolPaused.selector);
        engine.declareWealth(10_000 ether);
    }

    function test_ZakatRate_IsTwoPointFivePercent() public {
        vm.warp(block.timestamp + 354 days + 1);
        // 100,000 × 250 / 10,000 = 2,500 exactly
        assertEq(engine.zakatDue(payer), (100_000 ether * 250) / 10_000);
    }
}
