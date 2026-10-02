// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StakeVault} from "../src/StakeVault.sol";
import {MockToken} from "../src/MockToken.sol";
import {Ownable} from "../src/Ownable.sol";

contract StakeVaultTest is Test {
    StakeVault vault;
    MockToken staking;
    MockToken reward;

    address owner = address(this);
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address mallory = makeAddr("mallory");

    uint256 constant REWARDS = 1000 ether;
    uint256 constant DURATION = 10 days;
    uint256 constant RATE = REWARDS / DURATION;

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);
    event EmergencyWithdrawn(address indexed user, uint256 amount);

    function setUp() public {
        staking = new MockToken("Stake Token", "STAKE");
        reward = new MockToken("Reward Token", "REWARD");
        vault = new StakeVault(staking, reward, owner);

        staking.mint(alice, 1_000_000 ether);
        staking.mint(bob, 1_000_000 ether);
        vm.prank(alice);
        staking.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        staking.approve(address(vault), type(uint256).max);

        _fundRewards(REWARDS, DURATION);
    }

    /// Owner funds a new emission period.
    function _fundRewards(uint256 amount, uint256 duration) internal {
        reward.mint(owner, amount);
        reward.approve(address(vault), amount);
        vault.startRewards(amount, duration);
    }

    /* ==================== STAKING ==================== */

    function test_Stake_RecordsBalanceAndPullsTokens() public {
        vm.expectEmit(true, false, true, true);
        emit Staked(alice, 1000 ether);
        vm.prank(alice);
        vault.stake(1000 ether);

        assertEq(vault.totalSupply(), 1000 ether);
        assertEq(vault.balanceOf(alice), 1000 ether);
        assertEq(staking.balanceOf(address(vault)), 1000 ether);
        assertEq(staking.balanceOf(alice), 999_000 ether);
    }

    function test_Stake_ZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(StakeVault.ZeroAmount.selector);
        vault.stake(0);
    }

    function test_Stake_WithoutApprovalReverts() public {
        vm.prank(mallory); // never approved
        vm.expectRevert();
        vault.stake(1 ether);
    }

    /* ==================== REWARD MATH ==================== */

    function test_Earned_SingleStakerGetsFullRate() public {
        vm.prank(alice);
        vault.stake(1000 ether);
        vm.warp(block.timestamp + 5 days);

        // 5 of 10 days → ~half the rewards (tiny truncation from integer rate)
        uint256 expected = RATE * 5 days;
        assertApproxEqAbs(vault.earned(alice), expected, 1e15);
    }

    function test_Earned_ZeroBeforeFunding() public {
        // A vault that was never funded must not accrue anything.
        StakeVault unfunded = new StakeVault(staking, reward, owner);
        vm.prank(alice);
        staking.approve(address(unfunded), type(uint256).max);
        vm.prank(alice);
        unfunded.stake(1000 ether);
        vm.warp(block.timestamp + 5 days);
        assertEq(unfunded.earned(alice), 0);
    }

    function test_Earned_ProportionalToStake() public {
        vm.prank(alice);
        vault.stake(3000 ether);
        vm.prank(bob);
        vault.stake(1000 ether);
        vm.warp(block.timestamp + DURATION);

        assertApproxEqAbs(vault.earned(alice), 750 ether, 1e15); // 3/4
        assertApproxEqAbs(vault.earned(bob), 250 ether, 1e15); // 1/4
    }

    function test_Earned_LateStakerEarnsOnlyAfterEntry() public {
        vm.prank(alice);
        vault.stake(1000 ether);
        vm.warp(block.timestamp + 5 days);
        vm.prank(bob);
        vault.stake(1000 ether);
        vm.warp(block.timestamp + 5 days); // end of period

        // Alice: full rate for the first half alone (500) + half rate for the second (250)
        assertApproxEqAbs(vault.earned(alice), 750 ether, 2e15);
        // Bob: only the second half, sharing the pool with alice
        assertApproxEqAbs(vault.earned(bob), 250 ether, 2e15);
    }

    /* ==================== CLAIMING ==================== */

    function test_GetReward_PaysOutAndResets() public {
        vm.prank(alice);
        vault.stake(1000 ether);
        vm.warp(block.timestamp + 5 days);

        uint256 before = reward.balanceOf(alice);
        uint256 earned = vault.earned(alice);
        vm.expectEmit(true, false, true, true);
        emit RewardPaid(alice, earned);
        vm.prank(alice);
        vault.getReward();

        assertEq(reward.balanceOf(alice) - before, earned);
        assertEq(vault.rewards(alice), 0);
        assertEq(vault.earned(alice), 0);
    }

    function test_GetReward_CheckpointPreventsDoubleCounting() public {
        vm.prank(alice);
        vault.stake(1000 ether);
        vm.warp(block.timestamp + 5 days);
        vm.prank(alice);
        vault.getReward(); // claims the first half

        vm.warp(block.timestamp + 5 days);
        // Only the second half accrues — no double counting after the claim.
        assertApproxEqAbs(vault.earned(alice), 500 ether, 1e15);
    }

    function test_GetReward_WithNothingEarnedPaysZero() public {
        vm.prank(alice);
        vault.stake(1000 ether);
        vm.prank(alice);
        vault.getReward(); // no revert, nothing paid
        assertEq(reward.balanceOf(alice), 0);
    }

    /* ==================== WITHDRAW ==================== */

    function test_Withdraw_ReturnsTokensKeepsRewards() public {
        vm.prank(alice);
        vault.stake(1000 ether);
        vm.warp(block.timestamp + 5 days);

        vm.expectEmit(true, false, true, true);
        emit Withdrawn(alice, 400 ether);
        vm.prank(alice);
        vault.withdraw(400 ether);

        assertEq(vault.balanceOf(alice), 600 ether);
        assertEq(vault.totalSupply(), 600 ether);
        assertEq(staking.balanceOf(alice), 999_400 ether);
        assertGt(vault.earned(alice), 0); // rewards not lost on partial withdraw
    }

    function test_Withdraw_TooMuchReverts() public {
        vm.prank(alice);
        vault.stake(1000 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakeVault.InsufficientStake.selector, 1000 ether, 1001 ether));
        vault.withdraw(1001 ether);
    }

    function test_Withdraw_ZeroReverts() public {
        vm.prank(alice);
        vault.stake(1000 ether);
        vm.prank(alice);
        vm.expectRevert(StakeVault.ZeroAmount.selector);
        vault.withdraw(0);
    }

    function test_Exit_ReturnsEverythingAndPaysRewards() public {
        vm.prank(alice);
        vault.stake(1000 ether);
        vm.warp(block.timestamp + DURATION);

        vm.prank(alice);
        vault.exitAll();

        assertEq(vault.balanceOf(alice), 0);
        assertEq(staking.balanceOf(alice), 1_000_000 ether);
        assertApproxEqAbs(reward.balanceOf(alice), REWARDS, 1e15);
    }

    /* ==================== EMERGENCY WITHDRAW ==================== */

    function test_EmergencyWithdraw_ReturnsPrincipalForfeitsRewards() public {
        vm.prank(alice);
        vault.stake(1000 ether);
        vm.warp(block.timestamp + 5 days);
        uint256 vaultRewardsBefore = reward.balanceOf(address(vault));

        vm.expectEmit(true, false, true, true);
        emit EmergencyWithdrawn(alice, 1000 ether);
        vm.prank(alice);
        vault.emergencyWithdraw();

        assertEq(staking.balanceOf(alice), 1_000_000 ether);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.rewards(alice), 0); // forfeited
        // The forfeited reward tokens stay in the vault (documented dust).
        assertEq(reward.balanceOf(address(vault)), vaultRewardsBefore);

        vm.prank(alice);
        vault.getReward(); // nothing left to claim
        assertEq(reward.balanceOf(alice), 0);
    }

    function test_EmergencyWithdraw_ZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(StakeVault.ZeroAmount.selector);
        vault.emergencyWithdraw();
    }

    /* ==================== OWNER / EMISSIONS ==================== */

    function test_StartRewards_OnlyOwner() public {
        reward.mint(mallory, 100 ether);
        vm.prank(mallory);
        reward.approve(address(vault), 100 ether);
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(Ownable.NotOwner.selector, mallory));
        vault.startRewards(100 ether, 7 days);
    }

    function test_StartRewards_ZeroDurationReverts() public {
        reward.mint(owner, 100 ether);
        reward.approve(address(vault), 100 ether);
        vm.expectRevert(StakeVault.InvalidDuration.selector);
        vault.startRewards(100 ether, 0);
    }

    function test_StartRewards_MidPeriodRollsOverLeftover() public {
        vm.prank(alice);
        vault.stake(1000 ether);
        vm.warp(block.timestamp + 5 days);

        uint256 oldRate = vault.rewardRate();
        uint256 leftover = (vault.periodFinish() - block.timestamp) * oldRate;

        _fundRewards(1000 ether, 10 days);

        uint256 expectedNewRate = (1000 ether + leftover) / 10 days;
        assertEq(vault.rewardRate(), expectedNewRate);
        assertGt(vault.rewardRate(), oldRate);
        assertEq(vault.periodFinish(), block.timestamp + 10 days);
    }

    function test_AfterPeriod_NoFurtherAccrual() public {
        vm.prank(alice);
        vault.stake(1000 ether);
        vm.warp(block.timestamp + DURATION + 30 days); // well past the end

        assertApproxEqAbs(vault.earned(alice), REWARDS, 1e15); // capped, no runaway accrual
    }

    /* ==================== FUZZ ==================== */

    function testFuzz_SingleStakerEarnsLinear(uint256 amount, uint256 elapsed) public {
        amount = bound(amount, 1, 1_000_000 ether);
        elapsed = bound(elapsed, 1, DURATION);

        vm.prank(alice);
        vault.stake(amount);
        vm.warp(block.timestamp + elapsed);

        assertApproxEqAbs(vault.earned(alice), RATE * elapsed, 1e18);
    }

    function testFuzz_TwoStakersSplitProportionally(uint256 a, uint256 b) public {
        a = bound(a, 1, 100_000 ether);
        b = bound(b, 1, 100_000 ether);

        vm.prank(alice);
        vault.stake(a);
        vm.prank(bob);
        vault.stake(b);
        vm.warp(block.timestamp + 8 days);

        uint256 totalEmitted = RATE * 8 days;
        uint256 aliceExpected = (totalEmitted * a) / (a + b);
        assertApproxEqAbs(vault.earned(alice), aliceExpected, 1e16);
        assertApproxEqAbs(vault.earned(bob), totalEmitted - aliceExpected, 1e16);
    }

    function testFuzz_WithdrawAndRestakeKeepsAccountingSound(uint256 first, uint256 second) public {
        first = bound(first, 1, 10_000 ether);
        second = bound(second, 1, 10_000 ether);

        vm.prank(alice);
        vault.stake(first);
        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        vault.withdraw(first);
        vm.prank(alice);
        vault.stake(second);
        vm.warp(block.timestamp + 3 days);

        // Alice earned the full rate for 2 days (sole staker) + full rate for 3 more days.
        assertApproxEqAbs(vault.earned(alice), RATE * 5 days, 2e18);
    }
}
