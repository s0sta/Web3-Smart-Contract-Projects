// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {DamanFixture} from "./DamanFixture.sol";
import {DamanRegistry} from "../src/DamanRegistry.sol";
import {DamanOracle} from "../src/DamanOracle.sol";
import {DamanPricing, DamanLines} from "../src/DamanPricing.sol";
import {DamanTreasury} from "../src/DamanTreasury.sol";
import {DamanPremiums} from "../src/DamanPremiums.sol";
import {DamanPolicies} from "../src/DamanPolicies.sol";
import {DamanClaims} from "../src/DamanClaims.sol";
import {DamanParametric} from "../src/DamanParametric.sol";
import {DamanReinsurance} from "../src/DamanReinsurance.sol";
import {DamanSurplus} from "../src/DamanSurplus.sol";
import {DamanGovernor} from "../src/DamanGovernor.sol";

contract DamanRegistryTest is DamanFixture {
    function test_Register() public {
        assertEq(uint8(registry.roleOf(holder)), uint8(DamanRegistry.Role.Policyholder));
        assertEq(registry.participantCount(), 4);
    }

    function test_Freeze_OfficerOnly() public {
        vm.prank(outsider);
        vm.expectRevert(DamanRegistry.NotOfficer.selector);
        registry.setFrozen(holder, true);
        vm.prank(officer);
        registry.setFrozen(holder, true);
        assertFalse(registry.isActive(holder));
    }
}

contract DamanOracleTest is DamanFixture {
    function test_Condition_NotTriggered() public {
        oracle.postMeasurement(bytes32(uint256(conditionId)), 100);
        assertFalse(oracle.checkCondition(conditionId));
    }

    function test_Condition_Triggered() public {
        oracle.postMeasurement(bytes32(uint256(conditionId)), 240);
        assertTrue(oracle.checkCondition(conditionId));
    }

    function test_Condition_Inactive() public {
        oracle.setConditionActive(conditionId, false);
        assertFalse(oracle.checkCondition(conditionId));
    }

    function test_Pause_Guardian() public {
        vm.prank(outsider);
        vm.expectRevert();
        oracle.pause();
        vm.prank(guardian);
        oracle.pause();
        vm.expectRevert(DamanOracle.FeedPaused.selector);
        oracle.price(address(aeds));
    }
}

contract DamanPricingTest is DamanFixture {
    function test_Quote_TravelStandard() public {
        // 10,000 cover, 3% annual, 1x risk, 30 days
        uint256 expected = (uint256(10_000 ether) * 300 / 10_000) * 30 / 365;
        assertEq(pricing.quote(DamanLines.Line.Travel, DamanPricing.RiskClass.Standard, 10_000 ether, 30), expected);
    }

    function test_Quote_HighRiskCostsMore() public {
        uint256 standard = pricing.quote(DamanLines.Line.Travel, DamanPricing.RiskClass.Standard, 10_000 ether, 30);
        uint256 high = pricing.quote(DamanLines.Line.Travel, DamanPricing.RiskClass.High, 10_000 ether, 30);
        assertTrue(high > standard);
    }

    function test_Quote_BandMultiplier() public {
        vm.prank(address(governor));
        pricing.addBand(DamanLines.Line.Travel, 5_000 ether, 12_000);
        uint256 withBand = pricing.quote(DamanLines.Line.Travel, DamanPricing.RiskClass.Standard, 10_000 ether, 30);
        uint256 base = (uint256(10_000 ether) * 300 / 10_000) * 30 / 365;
        assertEq(withBand, base * 12_000 / 10_000);
    }
}

contract DamanPoliciesTest is DamanFixture {
    function test_BuyPolicy() public {
        (address h, DamanLines.Line line, , uint256 cover, uint256 premium, , , , DamanPolicies.Status status) = policies.policies(policyId);
        assertEq(h, holder);
        assertEq(uint8(line), uint8(DamanLines.Line.Travel));
        assertEq(cover, 10_000 ether);
        assertTrue(premium > 0);
        assertEq(uint8(status), uint8(DamanPolicies.Status.Active));
    }

    function test_Buy_SplitsPremium() public {
        ( , , , , uint256 premium, , , , ) = policies.policies(policyId);
        uint256 fee = premium * 500 / 10_000;
        assertEq(treasury.totalFeesCollected(), fee);
        assertEq(premiums.pool(DamanLines.Line.Travel), 500_000 ether + premium - fee); // seed + share
    }

    function test_CoverBounds() public {
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(DamanPolicies.CoverOutOfBounds.selector, 1 ether, 100 ether, 100_000 ether));
        policies.buyPolicy(DamanLines.Line.Travel, DamanPricing.RiskClass.Standard, 1 ether, 30);
    }

    function test_Expire() public {
        vm.warp(block.timestamp + 31 days);
        policies.expire(policyId);
        ( , , , , , , , , DamanPolicies.Status status) = policies.policies(policyId);
        assertEq(uint8(status), uint8(DamanPolicies.Status.Expired));
    }

    function test_Buy_RequiresRegistration() public {
        vm.prank(outsider);
        vm.expectRevert();
        policies.buyPolicy(DamanLines.Line.Travel, DamanPricing.RiskClass.Standard, 1_000 ether, 30);
    }
}

contract DamanClaimsTest is DamanFixture {
    function test_File_OnlyHolder() public {
        vm.prank(outsider);
        vm.expectRevert(DamanClaims.NotAdjuster.selector);
        claims.fileClaim(policyId, 1_000 ether, "lost luggage", bytes32("ev"));
    }

    function test_File_OverCoverReverts() public {
        vm.prank(holder);
        vm.expectRevert(DamanClaims.ZeroAmount.selector);
        claims.fileClaim(policyId, 20_000 ether, "over", bytes32("ev"));
    }

    function test_Claim_TwoAdjustersPay() public {
        vm.prank(holder);
        uint256 cid = claims.fileClaim(policyId, 2_000 ether, "lost luggage", bytes32("ev"));
        vm.prank(adjuster1);
        claims.voteClaim(cid, true);
        uint256 before = aeds.balanceOf(holder);
        vm.prank(adjuster2);
        claims.voteClaim(cid, true);
        assertEq(aeds.balanceOf(holder) - before, 2_000 ether);
        ( , , , , , , , bool decided, bool approved) = claims.claims(cid);
        assertTrue(decided);
        assertTrue(approved);
        assertFalse(policies.isActivePolicy(policyId));
    }

    function test_Claim_Rejections() public {
        vm.prank(holder);
        uint256 cid = claims.fileClaim(policyId, 2_000 ether, "x", bytes32("ev"));
        vm.prank(adjuster1);
        claims.voteClaim(cid, false);
        vm.prank(adjuster2);
        claims.voteClaim(cid, false);
        ( , , , , , , , bool decided, bool approved) = claims.claims(cid);
        assertTrue(decided);
        assertFalse(approved);
        assertTrue(policies.isActivePolicy(policyId));
    }

    function test_Vote_AdjusterOnly() public {
        vm.prank(holder);
        uint256 cid = claims.fileClaim(policyId, 1_000 ether, "x", bytes32("ev"));
        vm.prank(outsider);
        vm.expectRevert();
        claims.voteClaim(cid, true);
    }
}

contract DamanParametricTest is DamanFixture {
    function test_BuyCover() public {
        vm.prank(holder);
        uint256 cid = parametric.buyCover(conditionId, 1_000 ether, 7);
        ( , , uint256 payout, uint256 premium, , , ) = parametric.covers(cid);
        assertEq(payout, 1_000 ether);
        assertEq(premium, 60 ether); // 6%
    }

    function test_Settle_Triggered() public {
        vm.prank(holder);
        uint256 cid = parametric.buyCover(conditionId, 1_000 ether, 7);
        oracle.postMeasurement(bytes32(uint256(conditionId)), 240); // triggered
        vm.warp(block.timestamp + 8 days);
        uint256 before = aeds.balanceOf(holder);
        parametric.settle(cid);
        assertEq(aeds.balanceOf(holder) - before, 1_000 ether);
    }

    function test_Settle_NotTriggered() public {
        vm.prank(holder);
        uint256 cid = parametric.buyCover(conditionId, 1_000 ether, 7);
        oracle.postMeasurement(bytes32(uint256(conditionId)), 100); // below threshold
        vm.warp(block.timestamp + 8 days);
        uint256 before = aeds.balanceOf(holder);
        parametric.settle(cid);
        assertEq(aeds.balanceOf(holder), before);
    }

    function test_Settle_BeforeWindow() public {
        vm.prank(holder);
        uint256 cid = parametric.buyCover(conditionId, 1_000 ether, 7);
        vm.expectRevert(abi.encodeWithSelector(DamanParametric.WindowClosed.selector, cid));
        parametric.settle(cid);
    }

    function test_Cap_Enforced() public {
        parametric.setCap(conditionId, 500 ether);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(DamanParametric.CapExceeded.selector, conditionId, 500 ether));
        parametric.buyCover(conditionId, 1_000 ether, 7);
    }
}

contract DamanReinsuranceTest is DamanFixture {
    function test_CedeShare() public {
        ( , , , , uint256 premium, , , , ) = policies.policies(policyId);
        uint256 share = premium * 1500 / 10_000;
        reinsurance.cedeShare(DamanLines.Line.Travel, premium);
        assertEq(reinsurance.pool(DamanLines.Line.Travel), 100_000 ether + share); // seed + cession
    }

    function test_Recovery_AboveAttachment() public {
        // fund the reinsurance pool via a cession
        ( , , , , uint256 premium, , , , ) = policies.policies(policyId);
        reinsurance.cedeShare(DamanLines.Line.Travel, premium);
        // a 1,500 claim → recovery = (1,500 − 1,000) × 90% = 450
        uint256 before = aeds.balanceOf(address(reinsurance));
        uint256 rec = reinsurance.recover(DamanLines.Line.Travel, 1_500 ether);
        assertEq(rec, 450 ether);
        assertEq(aeds.balanceOf(address(reinsurance)), before - 450 ether);
    }

    function test_Recovery_BelowAttachment() public {
        assertEq(reinsurance.recover(DamanLines.Line.Travel, 500 ether), 0);
    }
}

contract DamanSurplusTest is DamanFixture {
    function test_Distribute_NoClaims() public {
        ( , , , , uint256 premium, , , , ) = policies.policies(policyId);
        vm.warp(block.timestamp + 31 days);
        policies.expire(policyId);
        uint256[] memory ids = new uint256[](1);
        ids[0] = policyId;
        uint256 before = aeds.balanceOf(holder);
        surplus.distributeSurplus(DamanLines.Line.Travel, ids, premium);
        assertTrue(aeds.balanceOf(holder) > before);
    }

    function test_ClaimedPolicy_Excluded() public {
        vm.prank(holder);
        uint256 cid = claims.fileClaim(policyId, 2_000 ether, "x", bytes32("ev"));
        vm.prank(adjuster1);
        claims.voteClaim(cid, true);
        vm.prank(adjuster2);
        claims.voteClaim(cid, true);
        vm.warp(block.timestamp + 31 days);
        uint256[] memory ids = new uint256[](1);
        ids[0] = policyId;
        vm.expectRevert(abi.encodeWithSelector(DamanSurplus.NothingToDistribute.selector, DamanLines.Line.Travel));
        surplus.distributeSurplus(DamanLines.Line.Travel, ids, 0);
    }
}

contract DamanGovernorTest is DamanFixture {
    function test_Propose_PremiumWeighted() public {
        governor.recordPremium(holder, 100 ether);
        vm.prank(holder);
        uint256 id = governor.propose(address(pricing), 0, abi.encodeCall(pricing.setBaseRate, (DamanLines.Line.Travel, 350)), "raise travel rate");
        vm.warp(block.timestamp + 3 days);
        vm.prank(holder);
        governor.vote(id, true);
        ( , , , , , uint256 forV, , , , , , , ) = governor.proposals(id);
        assertEq(forV, 100 ether);
    }

    function test_FullLifecycle_ChangesRate() public {
        governor.recordPremium(holder, 100 ether);
        vm.prank(holder);
        uint256 id = governor.propose(address(pricing), 0, abi.encodeCall(pricing.setBaseRate, (DamanLines.Line.Travel, 350)), "raise rate");
        vm.warp(block.timestamp + 3 days);
        vm.prank(holder);
        governor.vote(id, true);
        vm.warp(block.timestamp + 10 days);
        assertEq(governor.state(id), 3);
        governor.execute(id);
        assertEq(governor.state(id), 4);
        assertEq(pricing.baseRateBps(DamanLines.Line.Travel), 350);
    }

    function test_InvalidTarget_Rejected() public {
        vm.expectRevert(DamanGovernor.InvalidTargets.selector);
        governor.propose(address(0xDEAD), 0, hex"1234", "escape");
    }

    function test_Timelock_BlocksEarly() public {
        governor.recordPremium(holder, 100 ether);
        vm.prank(holder);
        uint256 id = governor.propose(address(pricing), 0, abi.encodeCall(pricing.setBaseRate, (DamanLines.Line.Travel, 350)), "timelocked");
        vm.warp(block.timestamp + 3 days);
        vm.prank(holder);
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
        vm.expectRevert(DamanGovernor.ProtocolPaused.selector);
        governor.propose(address(pricing), 0, hex"1234", "paused");
    }
}
