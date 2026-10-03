// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {TakafulFixture} from "./TakafulFixture.sol";
import {TakafulPool} from "../src/TakafulPool.sol";

contract TakafulPoolTest is TakafulFixture {
    /* ---------- pool registration ---------- */

    function test_RegisterPool_OperatorOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        pool.registerPool("Health", 100 ether, 1000, 1_000 ether, 30 days, 30 days);

        vm.prank(operator);
        pool.registerPool("Health", 100 ether, 1000, 1_000 ether, 30 days, 30 days);
        (string memory name, , , , , , , , , bool active) = pool.pools(1);
        assertEq(name, "Health");
        assertTrue(active);
    }

    function test_RegisterPool_ZeroReverts() public {
        vm.expectRevert(TakafulPool.ZeroAmount.selector);
        pool.registerPool("Bad", 0, 1000, 1_000 ether, 30 days, 30 days);
        vm.expectRevert(TakafulPool.ZeroAmount.selector);
        pool.registerPool("Bad", 100 ether, 10_001, 1_000 ether, 30 days, 30 days);
    }

    /* ---------- joining (tabarru) ---------- */

    function test_Join_IssuesPolicyAndWithholdsWakalah() public {
        uint256 id = _join(alice);
        (uint256 poolId, address holder, , , uint256 contrib, , bool active) = pool.policies(id);
        assertEq(poolId, motorPoolId);
        assertEq(holder, alice);
        assertEq(contrib, 450 ether); // 500 − 10%
        assertTrue(active);
        assertEq(pool.totalWakalahFees(), 50 ether);
        ( , , , , , , uint256 totalContrib, , , ) = pool.pools(motorPoolId);
        assertEq(totalContrib, 450 ether);
    }

    function test_Join_TransfersFunds() public {
        uint256 before = stable.balanceOf(alice);
        _join(alice);
        assertEq(before - stable.balanceOf(alice), 500 ether);
        assertEq(stable.balanceOf(address(pool)), 500 ether);
    }

    function test_Join_RequiresApproval() public {
        vm.prank(outsider);
        vm.expectRevert();
        pool.joinPool(motorPoolId);
    }

    /* ---------- claims ---------- */

    function test_FileClaim_HolderOnlyWithinCoverage() public {
        uint256 id = _join(alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TakafulPool.NotPolicyHolder.selector, id));
        pool.fileClaim(id, 100 ether, "bumper");

        vm.prank(alice);
        uint256 claimId = pool.fileClaim(id, 100 ether, "bumper");
        (uint256 policyId, uint256 amount, , , , , , ) = pool.claims(claimId);
        assertEq(policyId, id);
        assertEq(amount, 100 ether);
    }

    function test_FileClaim_ExpiredPolicyReverts() public {
        uint256 id = _join(alice);
        vm.warp(block.timestamp + 91 days);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TakafulPool.PolicyExpired.selector, id));
        pool.fileClaim(id, 100 ether, "too late");
    }

    function test_FileClaim_ExceedsLimitReverts() public {
        uint256 id = _join(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TakafulPool.PolicyClaimLimit.selector, 0, 2_000 ether));
        pool.fileClaim(id, 2_500 ether, "total loss");
    }

    /* ---------- the claims committee ---------- */

    function test_VoteClaim_AssessorOnly() public {
        uint256 id = _join(alice);
        vm.prank(alice);
        uint256 claimId = pool.fileClaim(id, 100 ether, "bumper");
        vm.prank(outsider);
        vm.expectRevert();
        pool.voteClaim(claimId, true);
    }

    function test_VoteClaim_RequiresTwoApprovals() public {
        uint256 id = _join(alice);
        vm.prank(alice);
        uint256 claimId = pool.fileClaim(id, 100 ether, "bumper");

        vm.prank(assessor1);
        pool.voteClaim(claimId, true);
        assertEq(stable.balanceOf(alice), 99_500 ether); // not paid yet

        vm.prank(assessor2);
        pool.voteClaim(claimId, true);
        assertEq(stable.balanceOf(alice), 99_600 ether); // paid
    }

    function test_VoteClaim_CannotVoteTwice() public {
        uint256 id = _join(alice);
        vm.prank(alice);
        uint256 claimId = pool.fileClaim(id, 100 ether, "bumper");
        vm.prank(assessor1);
        pool.voteClaim(claimId, true);
        vm.prank(assessor1);
        vm.expectRevert(abi.encodeWithSelector(TakafulPool.AlreadyVoted.selector, claimId, assessor1));
        pool.voteClaim(claimId, true);
    }

    function test_VoteClaim_RejectionsCloseTheClaim() public {
        uint256 id = _join(alice);
        vm.prank(alice);
        uint256 claimId = pool.fileClaim(id, 100 ether, "bumper");
        vm.prank(assessor1);
        pool.voteClaim(claimId, false);
        vm.prank(assessor2);
        pool.voteClaim(claimId, false); // 2 approvals unreachable
        ( , , , , , uint256 rej, bool decided, bool approved) = pool.claims(claimId);
        assertTrue(decided);
        assertFalse(approved);
        assertEq(stable.balanceOf(alice), 99_500 ether); // unpaid
    }

    /* ---------- qard hasan bridge ---------- */

    function test_QardHasan_BridgesDeficientPool() public {
        // alice alone in the pool: net contributions = 450; claim 2,000 needs a bridge
        uint256 id = _join(alice);
        vm.prank(alice);
        uint256 claimId = pool.fileClaim(id, 2_000 ether, "total loss");

        // without the facility the claim cannot settle
        vm.prank(assessor1);
        pool.voteClaim(claimId, true);
        vm.prank(assessor2);
        vm.expectRevert(abi.encodeWithSelector(TakafulPool.InsufficientQardHasan.selector, 0, 1_500 ether));
        pool.voteClaim(claimId, true);

        // fund the facility
        stable.mint(operator, 2_000 ether);
        stable.approve(address(pool), 2_000 ether);
        pool.fundQardHasan(2_000 ether);

        vm.prank(assessor2);
        pool.voteClaim(claimId, true); // settles via the bridge
        assertEq(stable.balanceOf(alice), 101_500 ether); // 99,500 + 2,000 payout
        ( , , , , , , , , uint256 drawn, ) = pool.pools(motorPoolId);
        assertEq(drawn, 1_500 ether);
    }

    function test_RepayQardHasan_OperatorOnly() public {
        stable.mint(operator, 1_000 ether);
        stable.approve(address(pool), 1_000 ether);
        pool.fundQardHasan(1_000 ether);
        assertEq(pool.qardHasanFacility(), 1_000 ether);

        vm.prank(outsider);
        vm.expectRevert();
        pool.repayQardHasan(1 ether);
    }

    /* ---------- surplus (no-claim benefit) ---------- */

    function test_Surplus_PaidToNonClaimersOnly() public {
        uint256 alicePolicy = _join(alice);
        uint256 bobPolicy = _join(bob);
        _join(address(0x1));
        _join(address(0x2));
        _join(address(0x3)); // 5 participants × 450 net = 2,250

        // bob claims 300 → paid from the pool
        vm.prank(bob);
        uint256 claimId = pool.fileClaim(bobPolicy, 300 ether, "scrape");
        // policyId for bob is alicePolicy + 1
        vm.prank(assessor1);
        pool.voteClaim(claimId, true);
        vm.prank(assessor2);
        pool.voteClaim(claimId, true);

        // reserve floor = 10 × 500 = 5,000; available = 2,250 + 50 fees − 300 = 2,000 < 5,000 → no surplus
        address[] memory participants = new address[](5);
        participants[0] = alice;
        participants[1] = bob;
        participants[2] = address(0x1);
        participants[3] = address(0x2);
        participants[4] = address(0x3);
        vm.expectRevert(TakafulPool.NoSurplus.selector);
        pool.distributeSurplus(motorPoolId, participants);

        // fund the pool well above the floor via investment income
        stable.mint(operator, 20_000 ether);
        stable.approve(address(pool), 20_000 ether);
        pool.recordInvestmentIncome(20_000 ether);

        uint256 aliceBefore = stable.balanceOf(alice);
        uint256 surplus = pool.distributeSurplus(motorPoolId, participants);
        assertTrue(surplus > 0);
        assertTrue(stable.balanceOf(alice) > aliceBefore); // non-claimer got a share
        assertEq(pool.claimedThisPeriod(motorPoolId, bob), true);
    }

    function test_Surplus_OperatorOnly() public {
        address[] memory participants = new address[](0);
        vm.prank(outsider);
        vm.expectRevert();
        pool.distributeSurplus(motorPoolId, participants);
    }

    /* ---------- snapshots & pause ---------- */

    function test_ContributionSnapshots() public {
        _join(alice);
        vm.roll(block.number + 1);
        _join(alice);
        assertEq(pool.getPastContribution(motorPoolId, alice, block.number), 900 ether);
        assertEq(pool.getPastContribution(motorPoolId, alice, block.number - 1), 450 ether);
    }

    function test_Pause_GuardianOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        pool.pause();

        vm.prank(guardian);
        pool.pause();
        vm.prank(alice);
        vm.expectRevert(TakafulPool.ProtocolPaused.selector);
        pool.joinPool(motorPoolId);
    }
}
