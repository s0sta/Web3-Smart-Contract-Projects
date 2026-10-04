// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {RahalaFixture} from "./RahalaFixture.sol";
import {RahalaStable} from "../src/RahalaStable.sol";
import {RahalaCompliance} from "../src/RahalaCompliance.sol";
import {RahalaOracle} from "../src/RahalaOracle.sol";
import {RahalaAccounts} from "../src/RahalaAccounts.sol";
import {RahalaTreasury} from "../src/RahalaTreasury.sol";
import {RahalaFX} from "../src/RahalaFX.sol";
import {RahalaEscrow} from "../src/RahalaEscrow.sol";
import {RahalaInvoices} from "../src/RahalaInvoices.sol";
import {RahalaSettlement} from "../src/RahalaSettlement.sol";
import {RahalaDisputes} from "../src/RahalaDisputes.sol";
import {RahalaGovernor} from "../src/RahalaGovernor.sol";

contract RahalaStableTest is RahalaFixture {
    function test_Erc20_Basics() public {
        assertEq(aeds.name(), "Rahala AED Stable");
        assertEq(aeds.totalSupply(), 1_300_000 ether); // 300k credits + 1M FX float
        vm.prank(alice);
        aeds.transfer(bob, 1_000 ether);
        assertEq(aeds.balanceOf(bob), 101_000 ether);
    }

    function test_MintBurn_IssuerOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        aeds.mint(outsider, 1 ether);
    }

    function test_TransferFrom_Allowance() public {
        vm.prank(alice);
        aeds.approve(bob, 500 ether);
        vm.prank(bob);
        aeds.transferFrom(alice, bob, 300 ether);
        assertEq(aeds.balanceOf(alice), 99_700 ether);
    }
}

contract RahalaComplianceTest is RahalaFixture {
    function test_TransferCap_Enforced() public {
        vm.prank(officer);
        compliance.setCaps(RahalaCompliance.KycTier.Standard, 1_000 ether, 100_000 ether);
        vm.expectRevert(abi.encodeWithSelector(RahalaCompliance.TransferLimit.selector, 2_000 ether, 1_000 ether));
        compliance.validateTransfer(alice, bob, REGION_UAE, 2_000 ether, bytes32(0));
    }

    function test_Region_Blocked() public {
        vm.expectRevert(abi.encodeWithSelector(RahalaCompliance.RegionBlocked.selector, uint64(999)));
        compliance.validateTransfer(alice, bob, 999, 100 ether, bytes32(0));
    }

    function test_Sanction_Blocks() public {
        vm.prank(officer);
        compliance.setSanctioned(bob, true);
        vm.expectRevert();
        compliance.validateTransfer(alice, bob, REGION_UAE, 100 ether, bytes32(0));
    }
}

contract RahalaOracleTest is RahalaFixture {
    function test_Ema_Smooths() public {
        oracle.postRate(address(usdToken), 3_670_000_000_000_000_000);
        vm.warp(block.timestamp + 30 minutes);
        oracle.postRate(address(usdToken), 4_670_000_000_000_000_000);
        uint256 r = oracle.rate(address(usdToken));
        assertTrue(r > 3_670_000_000_000_000_000 && r < 4_670_000_000_000_000_000);
    }

    function test_Stale_Reverts() public {
        vm.warp(block.timestamp + 25 hours);
        vm.expectRevert();
        oracle.rate(address(usdToken));
    }

    function test_Pause_Guardian() public {
        vm.prank(outsider);
        vm.expectRevert();
        oracle.pause();
        vm.prank(guardian);
        oracle.pause();
        vm.expectRevert(RahalaOracle.FeedPaused.selector);
        oracle.rate(address(usdToken));
    }
}

contract RahalaAccountsTest is RahalaFixture {
    function test_Credit_Debit() public {
        uint256 before = aeds.balanceOf(alice);
        accounts.debit(alice, 10_000 ether);
        assertEq(aeds.balanceOf(alice), before - 10_000 ether);
        assertEq(accounts.balanceOf(alice), 90_000 ether);
    }

    function test_Debit_Insufficient() public {
        vm.expectRevert(abi.encodeWithSelector(RahalaAccounts.InsufficientBalance.selector, 100_000 ether, 200_000 ether));
        accounts.debit(alice, 200_000 ether);
    }

    function test_Snapshots() public {
        vm.roll(block.number + 1);
        accounts.credit(alice, 5_000 ether);
        assertEq(accounts.getPastBalance(alice, block.number), 105_000 ether);
        assertEq(accounts.getPastBalance(alice, block.number - 1), 100_000 ether);
    }
}

contract RahalaFxTest is RahalaFixture {
    function test_ConvertTo_USD() public {
        // 3,670 AED → 1,000 USD minus 0.5% fee and 0.2% spread
        vm.prank(alice);
        uint256 out = fx.convertTo(address(usdToken), 3_670 ether, 900 ether);
        uint256 expected = 1_000 ether - 5 ether - 2 ether;
        assertEq(out, expected);
        assertEq(usdToken.balanceOf(alice), expected);
    }

    function test_ConvertTo_SlippageReverts() public {
        vm.prank(alice);
        vm.expectRevert();
        fx.convertTo(address(usdToken), 3_670 ether, 1_000 ether);
    }

    function test_ConvertFrom_AED() public {
        usdToken.mint(alice, 10_000 ether);
        vm.prank(alice);
        usdToken.approve(address(fx), 10_000 ether);
        uint256 before = aeds.balanceOf(alice);
        vm.prank(alice);
        uint256 out = fx.convertFrom(address(usdToken), 1_000 ether, 0);
        // 1,000 USD × 3.67 = 3,670 − 0.5% fee
        uint256 expected = 3_670 ether - (3_670 ether * 50) / 10_000;
        assertEq(out, expected);
        assertEq(aeds.balanceOf(alice) - before, expected);
    }

    function test_Fee_ToTreasury() public {
        vm.prank(alice);
        fx.convertTo(address(usdToken), 3_670 ether, 0);
        assertEq(treasury.totalFeesCollected(), 5 ether);
    }

    function test_UnknownCurrency() public {
        vm.prank(alice);
        vm.expectRevert();
        fx.convertTo(address(0xDEAD), 1 ether, 0);
    }
}

contract RahalaEscrowTest is RahalaFixture {
    function _createInstant() internal returns (uint256) {
        vm.prank(alice);
        return escrow.createPayment(bob, 10_000 ether, 0, 0, 0, REGION_UAE, bytes32(0));
    }

    function test_Instant_Claim() public {
        uint256 id = _createInstant();
        uint256 before = aeds.balanceOf(bob);
        vm.prank(bob);
        escrow.claim(id);
        // 0.25% fee
        assertEq(aeds.balanceOf(bob) - before, 10_000 ether - 25 ether);
        assertEq(treasury.totalFeesCollected(), 25 ether);
    }

    function test_Timelocked_EarlyClaimReverts() public {
        vm.prank(alice);
        uint256 id = escrow.createPayment(bob, 10_000 ether, 1, 0, uint64(block.timestamp + 7 days), REGION_UAE, bytes32(0));
        vm.prank(bob);
        vm.expectRevert();
        escrow.claim(id);
        vm.warp(block.timestamp + 8 days);
        vm.prank(bob);
        escrow.claim(id);
    }

    function test_Milestones_TwoApprovals() public {
        vm.prank(alice);
        uint256 id = escrow.createPayment(bob, 10_000 ether, 2, 2, 0, REGION_UAE, bytes32(0));
        escrow.approvePayment(id);
        vm.prank(bob);
        vm.expectRevert();
        escrow.claim(id); // only 1 of 2 approvals
        uint256 before = aeds.balanceOf(bob);
        escrow.approvePayment(id); // the second approval auto-releases
        assertEq(aeds.balanceOf(bob) - before, 10_000 ether - 25 ether);
    }

    function test_Refund_SenderOnly() public {
        uint256 id = _createInstant();
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(RahalaEscrow.NotSender.selector, id));
        escrow.refund(id);
        uint256 before = aeds.balanceOf(alice);
        vm.prank(alice);
        escrow.refund(id);
        assertEq(aeds.balanceOf(alice) - before, 10_000 ether);
    }

    function test_Claim_NotRecipient() public {
        uint256 id = _createInstant();
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(RahalaEscrow.NotSender.selector, id));
        escrow.claim(id);
    }

    function test_ComplianceGate_BlocksUnKyc() public {
        vm.prank(outsider);
        vm.expectRevert();
        escrow.createPayment(bob, 1 ether, 0, 0, 0, REGION_UAE, bytes32(0));
    }
}

contract RahalaInvoicesTest is RahalaFixture {
    function _register() internal returns (uint256) {
        vm.prank(bob);
        return invoices.registerInvoice(alice, 10_000 ether, uint64(block.timestamp + 30 days), REGION_UAE, "supply of goods");
    }

    function test_Register_Factor() public {
        uint256 id = _register();
        uint256 before = aeds.balanceOf(bob);
        vm.prank(financier);
        invoices.factor(id);
        assertEq(aeds.balanceOf(bob) - before, 9_700 ether); // 3% discount
        ( , , uint256 face, uint256 advanced, address fin, , , , RahalaInvoices.Status status) = invoices.invoices(id);
        assertEq(face, 10_000 ether);
        assertEq(advanced, 9_700 ether);
        assertEq(fin, financier);
        assertEq(uint8(status), uint8(RahalaInvoices.Status.Factored));
    }

    function test_Settle_PaysFactor() public {
        uint256 id = _register();
        vm.prank(financier);
        invoices.factor(id);
        vm.prank(alice);
        aeds.approve(address(invoices), 10_000 ether);
        uint256 before = aeds.balanceOf(financier);
        vm.prank(alice);
        invoices.settle(id);
        assertEq(aeds.balanceOf(financier) - before, 10_000 ether);
    }

    function test_Factor_AlreadyFactored() public {
        uint256 id = _register();
        vm.prank(financier);
        invoices.factor(id);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RahalaInvoices.InvalidState.selector, id, RahalaInvoices.Status.Open, RahalaInvoices.Status.Factored));
        invoices.factor(id);
    }

    function test_Cancel_OpenOnly() public {
        uint256 id = _register();
        vm.prank(bob);
        invoices.cancel(id);
        ( , , , , , , , , RahalaInvoices.Status status) = invoices.invoices(id);
        assertEq(uint8(status), uint8(RahalaInvoices.Status.Canceled));
    }
}

contract RahalaSettlementTest is RahalaFixture {
    function test_Batch_Netting() public {
        netting.openBatch();
        netting.addObligation(alice, bob, 5_000 ether);
        netting.addObligation(bob, alice, 3_000 ether); // net: alice → bob 2,000
        vm.prank(alice);
        aeds.approve(address(netting), 5_000 ether);

        address[] memory debtors = new address[](1);
        debtors[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 2_000 ether;
        netting.settleBatch(debtors, amounts);
        assertEq(netting.nettedTotal(), 2_000 ether);
    }

    function test_Batch_ClosedWithoutOpen() public {
        address[] memory debtors = new address[](0);
        uint256[] memory amounts = new uint256[](0);
        vm.expectRevert(RahalaSettlement.BatchClosed.selector);
        netting.settleBatch(debtors, amounts);
    }
}

contract RahalaDisputesTest is RahalaFixture {
    function _fileDispute() internal returns (uint256) {
        return disputes.fileDispute(0, bytes32("evidence-001"), "goods not received");
    }

    function test_Arbitration_TwoVotesAward() public {
        uint256 id = _fileDispute();
        vm.prank(arbiter1);
        disputes.vote(id, true);
        ( , , , , , , bool decided0, ) = disputes.disputes(id);
        assertFalse(decided0);
        vm.prank(arbiter2);
        disputes.vote(id, true);
        ( , , , , , , bool decided, bool toRecipient) = disputes.disputes(id);
        assertTrue(decided);
        assertTrue(toRecipient);
    }

    function test_Vote_ArbiterOnly() public {
        uint256 id = _fileDispute();
        vm.prank(outsider);
        vm.expectRevert();
        disputes.vote(id, true);
    }

    function test_Vote_Twice() public {
        uint256 id = _fileDispute();
        vm.prank(arbiter1);
        disputes.vote(id, true);
        vm.prank(arbiter1);
        vm.expectRevert(abi.encodeWithSelector(RahalaDisputes.AlreadyVoted.selector, id, arbiter1));
        disputes.vote(id, true);
    }
}

contract RahalaGovernorTest is RahalaFixture {
    function test_Propose_BalanceWeightedVote() public {
        vm.prank(alice);
        uint256 id = governor.propose(address(escrow), 0, abi.encodeCall(escrow.setEscrowFee, (50)), "raise escrow fee to 0.5%");
        vm.warp(block.timestamp + 3 days);
        vm.prank(alice);
        governor.vote(id, true);
        ( , , , , , uint256 forV, , , , , , , ) = governor.proposals(id);
        assertEq(forV, 100_000 ether);
    }

    function test_FullLifecycle_ChangesFee() public {
        vm.prank(alice);
        uint256 id = governor.propose(address(escrow), 0, abi.encodeCall(escrow.setEscrowFee, (50)), "raise fee");
        vm.warp(block.timestamp + 3 days);
        vm.prank(alice);
        governor.vote(id, true);
        vm.warp(block.timestamp + 10 days);
        assertEq(governor.state(id), 3);
        governor.execute(id);
        assertEq(governor.state(id), 4);
        assertEq(escrow.escrowFeeBps(), 50);
    }

    function test_InvalidTarget_Rejected() public {
        vm.expectRevert(RahalaGovernor.InvalidTargets.selector);
        governor.propose(address(0xDEAD), 0, hex"1234", "escape");
    }

    function test_Timelock_BlocksEarly() public {
        vm.prank(alice);
        uint256 id = governor.propose(address(escrow), 0, abi.encodeCall(escrow.setEscrowFee, (50)), "timelocked");
        vm.warp(block.timestamp + 3 days);
        vm.prank(alice);
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
        vm.expectRevert(RahalaGovernor.ProtocolPaused.selector);
        governor.propose(address(escrow), 0, hex"1234", "paused");
    }
}
