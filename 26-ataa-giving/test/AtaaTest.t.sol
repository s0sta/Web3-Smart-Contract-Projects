// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {AtaaFixture} from "./AtaaFixture.sol";
import {AtaaRegistry} from "../src/AtaaRegistry.sol";
import {AtaaOracle} from "../src/AtaaOracle.sol";
import {AtaaZakat} from "../src/AtaaZakat.sol";
import {AtaaVault} from "../src/AtaaVault.sol";
import {AtaaDonations} from "../src/AtaaDonations.sol";
import {AtaaAllocations} from "../src/AtaaAllocations.sol";
import {AtaaEmergency} from "../src/AtaaEmergency.sol";
import {AtaaSponsorships} from "../src/AtaaSponsorships.sol";
import {AtaaGovernor} from "../src/AtaaGovernor.sol";

contract AtaaRegistryTest is AtaaFixture {
    function test_RegisterDonor() public {
        assertTrue(registry.isDonor(donor));
    }

    function test_Beneficiary_OfficerOnly() public {
        vm.prank(outsider);
        vm.expectRevert(AtaaRegistry.NotOfficer.selector);
        registry.registerBeneficiary(bytes32("x"), AtaaRegistry.Category.Food, 100 ether, "x");
    }

    function test_Deactivate() public {
        vm.prank(officer);
        registry.deactivateBeneficiary(beneficiaryId);
        assertFalse(registry.isActiveBeneficiary(beneficiaryId));
    }
}

contract AtaaZakatTest is AtaaFixture {
    function test_BelowNisab_NoDue() public {
        vm.prank(donor);
        zakat.declareWealth(AtaaZakat.AssetClass.Cash, 10_000 ether);
        assertEq(zakat.due(donor, AtaaZakat.AssetClass.Cash), 0);
    }

    function test_AboveNisab_StartsHawl() public {
        vm.prank(donor);
        zakat.declareWealth(AtaaZakat.AssetClass.Cash, 100_000 ether);
        ( , uint64 hawlStart, , ) = zakat.positions(donor, AtaaZakat.AssetClass.Cash);
        assertTrue(hawlStart > 0);
        assertEq(zakat.due(donor, AtaaZakat.AssetClass.Cash), 0); // hawl not complete yet
    }

    function test_HawlCompletes_DueIsTwoPointFivePercent() public {
        vm.prank(donor);
        zakat.declareWealth(AtaaZakat.AssetClass.Cash, 100_000 ether);
        vm.warp(block.timestamp + 354 days + 1);
        assertEq(zakat.due(donor, AtaaZakat.AssetClass.Cash), 2_500 ether);
    }

    function test_WealthDropsBelowNisab_HawlResets() public {
        vm.prank(donor);
        zakat.declareWealth(AtaaZakat.AssetClass.Cash, 100_000 ether);
        vm.warp(block.timestamp + 100 days);
        vm.prank(donor);
        zakat.declareWealth(AtaaZakat.AssetClass.Cash, 10_000 ether); // below nisab
        vm.warp(block.timestamp + 300 days);
        assertEq(zakat.due(donor, AtaaZakat.AssetClass.Cash), 0);
        vm.prank(donor);
        zakat.declareWealth(AtaaZakat.AssetClass.Cash, 100_000 ether); // re-cross
        vm.warp(block.timestamp + 354 days + 1);
        assertEq(zakat.due(donor, AtaaZakat.AssetClass.Cash), 2_500 ether);
    }

    function test_PayZakat_MovesToVault() public {
        vm.prank(donor);
        zakat.declareWealth(AtaaZakat.AssetClass.Cash, 100_000 ether);
        vm.warp(block.timestamp + 354 days + 1);
        vm.prank(donor);
        zakat.payZakat(AtaaZakat.AssetClass.Cash, 2_500 ether);
        assertEq(aeds.balanceOf(address(vault)), 2_500 ether);
        assertEq(zakat.due(donor, AtaaZakat.AssetClass.Cash), 0); // paid, hawl restarted
    }

    function test_PayZakat_PartialAllowed() public {
        vm.prank(donor);
        zakat.declareWealth(AtaaZakat.AssetClass.Cash, 100_000 ether);
        vm.warp(block.timestamp + 354 days + 1);
        vm.prank(donor);
        zakat.payZakat(AtaaZakat.AssetClass.Cash, 1_000 ether);
        assertEq(zakat.due(donor, AtaaZakat.AssetClass.Cash), 1_500 ether);
    }

    function test_PayZakat_OverDueReverts() public {
        vm.prank(donor);
        zakat.declareWealth(AtaaZakat.AssetClass.Cash, 100_000 ether);
        vm.warp(block.timestamp + 354 days + 1);
        vm.prank(donor);
        vm.expectRevert(abi.encodeWithSelector(AtaaZakat.ExceedsDue.selector, 2_500 ether, 3_000 ether));
        zakat.payZakat(AtaaZakat.AssetClass.Cash, 3_000 ether);
    }

    function test_PayZakat_NothingDueReverts() public {
        vm.prank(donor);
        zakat.declareWealth(AtaaZakat.AssetClass.Cash, 100_000 ether);
        vm.prank(donor);
        vm.expectRevert();
        zakat.payZakat(AtaaZakat.AssetClass.Cash, 1 ether);
    }

    function test_Produce_RainFedTenPercent() public {
        assertEq(zakat.produceDue(653, AtaaZakat.Irrigation.RainFed), 65); // value-units
        assertEq(zakat.produceDue(653, AtaaZakat.Irrigation.Irrigated), 32);
    }

    function test_Produce_BelowNisabReverts() public {
        vm.prank(donor);
        vm.expectRevert(abi.encodeWithSelector(AtaaZakat.BelowNisab.selector, 100, 653));
        zakat.payProduceZakat(100, AtaaZakat.Irrigation.RainFed, 10 ether);
    }

    function test_Rikaz_TwentyPercent() public {
        vm.prank(donor);
        zakat.payRikaz(1_000 ether);
        assertEq(aeds.balanceOf(address(vault)), 200 ether);
    }

    function test_Livestock_Schedules() public {
        assertEq(zakat.sheepDue(39), 0);
        assertEq(zakat.sheepDue(40), 1);
        assertEq(zakat.sheepDue(121), 2);
        assertEq(zakat.camelDue(4), 0);
        assertEq(zakat.camelDue(5), 1);
        assertEq(zakat.cowDue(29), 0);
        assertEq(zakat.cowDue(30), 1);
    }
}

contract AtaaVaultTest is AtaaFixture {
    function _give() internal returns (uint256 cid) {
        vm.prank(donor);
        cid = donations.donate(10_000 ether, AtaaRegistry.Category.Families);
    }

    function test_Donation_Recorded() public {
        uint256 cid = _give();
        (address d, uint256 amount, , , ) = vault.contributions(cid);
        assertEq(d, donor);
        assertEq(amount, 10_000 ether);
        assertEq(vault.poolBalance(), 10_000 ether);
    }

    function test_Disburse_FifoProvenance() public {
        uint256 cid = _give();
        uint256 before = aeds.balanceOf(beneficiaryWallet);
        allocations.setBudget(AtaaRegistry.Category.Families, 10_000 ether);
        vault.disburse(beneficiaryId, beneficiaryWallet, 4_000 ether, "food baskets");
        assertEq(aeds.balanceOf(beneficiaryWallet) - before, 4_000 ether);
        ( , , uint256 allocated, , ) = vault.contributions(cid);
        assertEq(allocated, 4_000 ether);
        uint256[] memory outIds = vault.outflowsOfList(cid);
        assertEq(outIds.length, 1);
        (uint256 cId, uint256 bId, uint256 amt, , ) = vault.outflows(outIds[0]);
        assertEq(cId, cid);
        assertEq(bId, beneficiaryId);
        assertEq(amt, 4_000 ether);
    }

    function test_DonorReport() public {
        uint256 cid = _give();
        vault.disburse(beneficiaryId, beneficiaryWallet, 3_000 ether, "support");
        (uint256 given, uint256 allocated, uint256 unalloc, uint256[] memory ids, , ) = vault.donorReport(donor);
        assertEq(given, 10_000 ether);
        assertEq(allocated, 3_000 ether);
        assertEq(unalloc, 7_000 ether);
        assertEq(ids.length, 1);
        assertEq(ids[0], cid);
    }

    function test_Disburse_InsufficientPool() public {
        vm.expectRevert(abi.encodeWithSelector(AtaaVault.InsufficientPool.selector, 0, 1 ether));
        vault.disburse(beneficiaryId, beneficiaryWallet, 1 ether, "x");
    }
}

contract AtaaDonationsTest is AtaaFixture {
    function test_Donate_RequiresDonor() public {
        vm.prank(outsider);
        vm.expectRevert(AtaaDonations.ZeroAmount.selector);
        donations.donate(1 ether, AtaaRegistry.Category.Food);
    }

    function test_Donate_ZeroReverts() public {
        vm.prank(donor);
        vm.expectRevert(AtaaDonations.ZeroAmount.selector);
        donations.donate(0, AtaaRegistry.Category.Food);
    }
}

contract AtaaAllocationsTest is AtaaFixture {
    function _fund() internal {
        vm.prank(donor);
        donations.donate(20_000 ether, AtaaRegistry.Category.Orphans);
        allocations.setBudget(AtaaRegistry.Category.Orphans, 20_000 ether);
    }

    function test_Propose_CommitteeOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        allocations.propose(beneficiaryId, beneficiaryWallet, 1_000 ether, "x");
    }

    function test_TwoVotes_Execute() public {
        _fund();
        vm.prank(committee1);
        uint256 pid = allocations.propose(beneficiaryId, beneficiaryWallet, 5_000 ether, "orphan support");
        vm.prank(committee1);
        allocations.vote(pid, true);
        assertEq(aeds.balanceOf(beneficiaryWallet), 0);
        vm.prank(committee2);
        allocations.vote(pid, true);
        assertEq(aeds.balanceOf(beneficiaryWallet), 5_000 ether);
        ( , , , , , , bool executed, ) = allocations.proposals(pid);
        assertTrue(executed);
    }

    function test_BudgetExceeded() public {
        _fund();
        allocations.setBudget(AtaaRegistry.Category.Orphans, 3_000 ether);
        vm.prank(committee1);
        vm.expectRevert(abi.encodeWithSelector(AtaaAllocations.BudgetExceeded.selector, AtaaRegistry.Category.Orphans, 0, 3_000 ether));
        allocations.propose(beneficiaryId, beneficiaryWallet, 5_000 ether, "over budget");
    }

    function test_InactiveBeneficiary() public {
        vm.prank(officer);
        registry.deactivateBeneficiary(beneficiaryId);
        vm.prank(committee1);
        vm.expectRevert(abi.encodeWithSelector(AtaaAllocations.InactiveBeneficiary.selector, beneficiaryId));
        allocations.propose(beneficiaryId, beneficiaryWallet, 1_000 ether, "x");
    }
}

contract AtaaEmergencyTest is AtaaFixture {
    function test_Campaign_DonateAndDisburse() public {
        vm.prank(committee1);
        uint256 cid = emergencyDesk.openCampaign(beneficiaryId, beneficiaryWallet, 10_000 ether, 30, "flood relief");
        vm.prank(donor);
        emergencyDesk.donate(cid, 6_000 ether);
        assertEq(emergencyDesk.raisedOf(cid), 6_000 ether);
        vm.prank(committee1);
        emergencyDesk.fastDisburse(cid, 5_000 ether);
        assertEq(aeds.balanceOf(beneficiaryWallet), 5_000 ether);
    }

    function test_Donate_AfterDeadline() public {
        vm.prank(committee1);
        uint256 cid = emergencyDesk.openCampaign(beneficiaryId, beneficiaryWallet, 10_000 ether, 30, "relief");
        vm.warp(block.timestamp + 31 days);
        vm.prank(donor);
        vm.expectRevert(abi.encodeWithSelector(AtaaEmergency.CampaignExpired.selector, cid, uint64(block.timestamp - 1 days)));
        emergencyDesk.donate(cid, 1 ether);
    }

    function test_Open_CommitteeOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        emergencyDesk.openCampaign(beneficiaryId, beneficiaryWallet, 1 ether, 30, "x");
    }
}

contract AtaaSponsorshipsTest is AtaaFixture {
    function test_Pledge_RenewMonthly() public {
        vm.prank(donor);
        uint256 pid = sponsorships.pledge(beneficiaryId, 500 ether);
        vm.prank(donor);
        vm.expectRevert(abi.encodeWithSelector(AtaaSponsorships.NotDue.selector, pid, uint64(block.timestamp + 30 days)));
        sponsorships.renew(pid);
        vm.warp(block.timestamp + 31 days);
        vm.prank(donor);
        sponsorships.renew(pid);
        ( , , , , uint8 renewals, ) = sponsorships.pledges(pid);
        assertEq(renewals, 1);
        assertEq(aeds.balanceOf(address(vault)), 500 ether);
    }

    function test_Pause_Resume() public {
        vm.prank(donor);
        uint256 pid = sponsorships.pledge(beneficiaryId, 500 ether);
        vm.prank(donor);
        sponsorships.pause(pid);
        vm.warp(block.timestamp + 31 days);
        vm.prank(donor);
        vm.expectRevert(abi.encodeWithSelector(AtaaSponsorships.InactivePledge.selector, pid));
        sponsorships.renew(pid);
        vm.prank(donor);
        sponsorships.resume(pid);
        assertEq(sponsorships.totalMonthlyCommitted(), 500 ether);
    }

    function test_DoublePledge_Reverts() public {
        vm.prank(donor);
        sponsorships.pledge(beneficiaryId, 500 ether);
        vm.prank(donor);
        vm.expectRevert(abi.encodeWithSelector(AtaaSponsorships.AlreadyPledged.selector, donor, beneficiaryId));
        sponsorships.pledge(beneficiaryId, 100 ether);
    }
}

contract AtaaGovernorTest is AtaaFixture {
    function test_Propose_GivingWeighted() public {
        vm.prank(donor);
        donations.donate(10_000 ether, AtaaRegistry.Category.Families);
        governor.recordGiving(donor, 10_000 ether);
        vm.prank(donor);
        uint256 id = governor.propose(address(allocations), 0, abi.encodeCall(allocations.setBudget, (AtaaRegistry.Category.Orphans, 50_000 ether)), "raise orphan budget");
        vm.warp(block.timestamp + 3 days);
        vm.prank(donor);
        governor.vote(id, true);
        ( , , , , , uint256 forV, , , , , , , ) = governor.proposals(id);
        assertEq(forV, 10_000 ether);
    }

    function test_FullLifecycle_ChangesBudget() public {
        vm.prank(donor);
        donations.donate(10_000 ether, AtaaRegistry.Category.Families);
        governor.recordGiving(donor, 10_000 ether);
        vm.prank(donor);
        uint256 id = governor.propose(address(allocations), 0, abi.encodeCall(allocations.setBudget, (AtaaRegistry.Category.Orphans, 50_000 ether)), "raise budget");
        vm.warp(block.timestamp + 3 days);
        vm.prank(donor);
        governor.vote(id, true);
        vm.warp(block.timestamp + 10 days);
        assertEq(governor.state(id), 3);
        governor.execute(id);
        assertEq(governor.state(id), 4);
        assertEq(allocations.budgets(AtaaRegistry.Category.Orphans), 50_000 ether);
    }

    function test_InvalidTarget_Rejected() public {
        vm.expectRevert(AtaaGovernor.InvalidTargets.selector);
        governor.propose(address(0xDEAD), 0, hex"1234", "escape");
    }

    function test_Timelock_BlocksEarly() public {
        vm.prank(donor);
        donations.donate(10_000 ether, AtaaRegistry.Category.Families);
        governor.recordGiving(donor, 10_000 ether);
        vm.prank(donor);
        uint256 id = governor.propose(address(allocations), 0, abi.encodeCall(allocations.setBudget, (AtaaRegistry.Category.Orphans, 50_000 ether)), "timelocked");
        vm.warp(block.timestamp + 3 days);
        vm.prank(donor);
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
        vm.expectRevert(AtaaGovernor.ProtocolPaused.selector);
        governor.propose(address(allocations), 0, hex"1234", "paused");
    }
}
