// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TokenVesting} from "../src/TokenVesting.sol";
import {MockToken} from "../src/MockToken.sol";
import {Ownable} from "../src/Ownable.sol";

contract TokenVestingTest is Test {
    TokenVesting vesting;
    MockToken token;

    address owner = address(this);
    address alice = makeAddr("alice"); // beneficiary
    address bob = makeAddr("bob");
    address mallory = makeAddr("mallory");

    uint256 constant AMOUNT = 1000 ether;
    uint256 constant CLIFF = 30 days;
    uint256 constant DURATION = 90 days;
    uint256 start = 1_000_000; // fixed "deployment" timestamp for deterministic math

    event ScheduleCreated(address indexed beneficiary, uint256 amount, uint256 start, uint256 cliff, uint256 end);
    event Claimed(address indexed beneficiary, uint256 amount);
    event ScheduleRevoked(address indexed beneficiary, uint256 returnedToOwner);

    function setUp() public {
        token = new MockToken("Vesting Token", "VEST");
        vesting = new TokenVesting(token, owner);
        token.mint(owner, 10_000 ether);
        token.approve(address(vesting), 10_000 ether);
    }

    function _createSchedule() internal {
        vesting.createSchedule(alice, AMOUNT, start, CLIFF, DURATION);
    }

    /* ==================== CREATION ==================== */

    function test_CreateSchedule_PullsTokensAndStoresParams() public {
        vm.expectEmit(true, false, true, true);
        emit ScheduleCreated(alice, AMOUNT, start, start + CLIFF, start + CLIFF + DURATION);
        _createSchedule();

        (uint256 total, uint256 claimed, uint256 s, uint256 cliff, uint256 end, bool revoked, uint256 revokedAt) =
            vesting.schedules(alice);
        assertEq(total, AMOUNT);
        assertEq(claimed, 0);
        assertEq(s, start);
        assertEq(cliff, start + CLIFF);
        assertEq(end, start + CLIFF + DURATION);
        assertFalse(revoked);
        assertEq(revokedAt, 0);
        assertEq(token.balanceOf(address(vesting)), AMOUNT);
    }

    function test_CreateSchedule_OnlyOwner() public {
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(Ownable.NotOwner.selector, mallory));
        vesting.createSchedule(alice, AMOUNT, start, CLIFF, DURATION);
    }

    function test_CreateSchedule_InvalidParamsRevert() public {
        vm.expectRevert(TokenVesting.ZeroAmount.selector);
        vesting.createSchedule(alice, 0, start, CLIFF, DURATION);
        vm.expectRevert(TokenVesting.InvalidSchedule.selector);
        vesting.createSchedule(alice, AMOUNT, start, 0, DURATION);
        vm.expectRevert(TokenVesting.InvalidSchedule.selector);
        vesting.createSchedule(alice, AMOUNT, start, CLIFF, 0);
        vm.expectRevert(Ownable.ZeroAddress.selector);
        vesting.createSchedule(address(0), AMOUNT, start, CLIFF, DURATION);
    }

    function test_CreateSchedule_DuplicateReverts() public {
        _createSchedule();
        vm.expectRevert(abi.encodeWithSelector(TokenVesting.ScheduleExists.selector, alice));
        vesting.createSchedule(alice, 100 ether, start, CLIFF, DURATION);
    }

    /* ==================== VESTING MATH ==================== */

    function test_Vested_BeforeStartIsZero() public {
        _createSchedule();
        vm.warp(start - 1);
        assertEq(vesting.vestedAmount(alice), 0);
    }

    function test_Vested_DuringCliffIsZero() public {
        _createSchedule();
        vm.warp(start + CLIFF - 1);
        assertEq(vesting.vestedAmount(alice), 0);
    }

    function test_Vested_AtCliffBoundaryIsZero() public {
        _createSchedule();
        vm.warp(start + CLIFF);
        assertEq(vesting.vestedAmount(alice), 0);
    }

    function test_Vested_LinearBetweenCliffAndEnd() public {
        _createSchedule();
        vm.warp(start + CLIFF + DURATION / 2); // halfway through the vesting window
        assertEq(vesting.vestedAmount(alice), AMOUNT / 2);
    }

    function test_Vested_FullAtEnd() public {
        _createSchedule();
        vm.warp(start + CLIFF + DURATION);
        assertEq(vesting.vestedAmount(alice), AMOUNT);
        vm.warp(start + CLIFF + DURATION + 3650 days);
        assertEq(vesting.vestedAmount(alice), AMOUNT);
    }

    /* ==================== CLAIMING ==================== */

    function test_Claim_PartialThenFull() public {
        _createSchedule();
        vm.warp(start + CLIFF + DURATION / 2);
        vm.prank(alice);
        vesting.claim();
        assertEq(token.balanceOf(alice), AMOUNT / 2);

        vm.warp(start + CLIFF + DURATION);
        vm.prank(alice);
        vesting.claim();
        assertEq(token.balanceOf(alice), AMOUNT);
        (uint256 total, uint256 claimed,,,,, ) = vesting.schedules(alice);
        assertEq(total, AMOUNT);
        assertEq(claimed, AMOUNT);
    }

    function test_Claim_BeforeCliffReverts() public {
        _createSchedule();
        vm.warp(start + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TokenVesting.NothingToClaim.selector, alice));
        vesting.claim();
    }

    function test_Claim_NoScheduleReverts() public {
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(TokenVesting.NoSchedule.selector, mallory));
        vesting.claim();
    }

    function test_Claim_NothingNewReverts() public {
        _createSchedule();
        vm.warp(start + CLIFF + DURATION);
        vm.prank(alice);
        vesting.claim();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TokenVesting.NothingToClaim.selector, alice));
        vesting.claim();
    }

    /* ==================== REVOCATION ==================== */

    function test_Revoke_ReturnsUnvestedKeepsVested() public {
        _createSchedule();
        vm.warp(start + CLIFF + DURATION / 2); // 50% vested

        uint256 ownerBefore = token.balanceOf(owner);
        vm.expectEmit(true, false, true, true);
        emit ScheduleRevoked(alice, AMOUNT / 2);
        vesting.revokeSchedule(alice);

        assertEq(token.balanceOf(owner) - ownerBefore, AMOUNT / 2);
        (,,,,, bool revoked,) = vesting.schedules(alice);
        assertTrue(revoked);
        // The vested half is still claimable by the beneficiary.
        assertEq(vesting.releasable(alice), AMOUNT / 2);
        vm.prank(alice);
        vesting.claim();
        assertEq(token.balanceOf(alice), AMOUNT / 2);
        // And nothing more ever vests.
        vm.warp(start + CLIFF + DURATION);
        assertEq(vesting.releasable(alice), 0);
    }

    function test_Revoke_OnlyOwner() public {
        _createSchedule();
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(Ownable.NotOwner.selector, mallory));
        vesting.revokeSchedule(alice);
    }

    function test_Revoke_TwiceReverts() public {
        _createSchedule();
        vesting.revokeSchedule(alice);
        vm.expectRevert(abi.encodeWithSelector(TokenVesting.AlreadyRevoked.selector, alice));
        vesting.revokeSchedule(alice);
    }

    function test_Revoke_UnknownBeneficiaryReverts() public {
        vm.expectRevert(abi.encodeWithSelector(TokenVesting.NoSchedule.selector, mallory));
        vesting.revokeSchedule(mallory);
    }

    /* ==================== FUZZ ==================== */

    function testFuzz_VestingCurveIsMonotonicAndCapped(uint256 t1, uint256 t2) public {
        _createSchedule();
        uint256 cliff = start + CLIFF;
        uint256 end = cliff + DURATION;
        t1 = bound(t1, 0, end + 10 days);
        t2 = bound(t2, 0, end + 10 days);

        vm.warp(t1);
        uint256 v1 = vesting.vestedAmount(alice);
        vm.warp(t2);
        uint256 v2 = vesting.vestedAmount(alice);

        assertLe(v1, AMOUNT);
        assertLe(v2, AMOUNT);
        if (t2 >= t1) assertGe(v2, v1);
        else assertGe(v1, v2); // vesting never decreases
        if (t1 >= end) assertEq(v1, AMOUNT);
    }

    function testFuzz_ClaimNeverPaysMoreThanVested(uint256 elapsed) public {
        _createSchedule();
        elapsed = bound(elapsed, 0, CLIFF + DURATION + 30 days);
        vm.warp(start + elapsed);

        uint256 before = vesting.releasable(alice);
        if (before > 0) {
            vm.prank(alice);
            vesting.claim();
            assertEq(token.balanceOf(alice), before);
        } else {
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(TokenVesting.NothingToClaim.selector, alice));
            vesting.claim();
        }
        (uint256 total, uint256 claimed,,,,, ) = vesting.schedules(alice);
        assertEq(claimed, before);
        assertLe(claimed, total);
    }

    function testFuzz_RevokeAccountingAlwaysBalances(uint256 elapsed) public {
        _createSchedule();
        elapsed = bound(elapsed, 0, CLIFF + DURATION + 10 days);
        vm.warp(start + elapsed);

        vesting.revokeSchedule(alice);

        // Vested (still claimable) + returned-to-owner == original grant.
        uint256 vested = vesting.vestedAmount(alice);
        assertLe(vested, AMOUNT);
        assertEq(token.balanceOf(address(vesting)) + token.balanceOf(owner), 10_000 ether);
        assertEq(vested, vesting.releasable(alice));
    }
}
