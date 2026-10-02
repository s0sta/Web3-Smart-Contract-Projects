// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CrowdFundFactory} from "../src/CrowdFundFactory.sol";
import {CrowdFundCampaign} from "../src/CrowdFundCampaign.sol";
import {Ownable} from "../src/Ownable.sol";

/// @notice A malicious backer that tries to re-enter `refund` from its receive function.
contract ReentrantBacker {
    CrowdFundCampaign campaign;
    bool attacking;

    constructor(CrowdFundCampaign campaign_) {
        campaign = campaign_;
    }

    function attack() external {
        attacking = true;
        campaign.refund();
    }

    receive() external payable {
        if (attacking) {
            attacking = false;
            campaign.refund(); // must revert thanks to the reentrancy guard
        }
    }
}

contract CrowdFundTest is Test {
    CrowdFundFactory factory;
    CrowdFundCampaign campaign;

    address owner = address(this);
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    uint256 constant GOAL = 10 ether;
    uint256 constant DURATION = 7 days;

    event Pledged(address indexed backer, uint256 amount);
    event Claimed(address indexed creator, uint256 amount);
    event Refunded(address indexed backer, uint256 amount);
    event CampaignCreated(
        uint256 indexed id, address indexed campaign, address indexed creator, uint256 goal, uint256 deadline
    );

    function setUp() public {
        factory = new CrowdFundFactory(100, owner); // 1% fee
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
        vm.deal(creator, 100 ether);
    }

    /// Creates a campaign as `creator` with the standard goal/duration.
    function _newCampaign() internal returns (CrowdFundCampaign c) {
        vm.prank(creator);
        c = factory.createCampaign(GOAL, DURATION);
    }

    /* ==================== FACTORY ==================== */

    function test_Factory_CreatesAndRegistersCampaign() public {
        uint256 expectedDeadline = block.timestamp + DURATION;
        vm.expectEmit(true, false, true, false);
        emit CampaignCreated(0, address(0), creator, GOAL, 0);
        vm.prank(creator);
        CrowdFundCampaign c = factory.createCampaign(GOAL, DURATION);

        assertEq(factory.campaignCount(), 1);
        assertEq(factory.allCampaigns(0), address(c));
        assertTrue(factory.isCampaign(address(c)));
        assertEq(c.creator(), creator);
        assertEq(c.goal(), GOAL);
        assertEq(c.deadline(), expectedDeadline);
        assertEq(c.feeBps(), 100);
    }

    function test_Factory_SetFeeBps_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.NotOwner.selector, alice));
        factory.setFeeBps(200);
    }

    function test_Factory_SetFeeBps_CappedAtMax() public {
        vm.expectRevert(abi.encodeWithSelector(CrowdFundFactory.FeeTooHigh.selector, 1001, 1000));
        factory.setFeeBps(1001);
    }

    function test_Factory_WithdrawFees_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.NotOwner.selector, alice));
        factory.withdrawFees(payable(alice));
    }

    function test_Factory_RejectsUnregisteredFeeCredit() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CrowdFundFactory.NotRegisteredCampaign.selector, alice));
        factory.creditFees(1 ether);
    }

    function test_Factory_RejectsZeroGoalOrDuration() public {
        vm.prank(creator);
        vm.expectRevert(CrowdFundCampaign.InvalidParams.selector);
        factory.createCampaign(0, DURATION);
        vm.prank(creator);
        vm.expectRevert(CrowdFundCampaign.InvalidParams.selector);
        factory.createCampaign(GOAL, 0);
    }

    /* ==================== PLEDGING ==================== */

    function test_Pledge_RecordsContribution() public {
        campaign = _newCampaign();
        vm.expectEmit(true, false, true, true);
        emit Pledged(alice, 4 ether);
        vm.prank(alice);
        campaign.pledge{value: 4 ether}();
        assertEq(campaign.totalPledged(), 4 ether);
        assertEq(campaign.pledged(alice), 4 ether);
        assertEq(address(campaign).balance, 4 ether);
    }

    function test_Pledge_MultipleBackersAccumulate() public {
        campaign = _newCampaign();
        vm.prank(alice);
        campaign.pledge{value: 4 ether}();
        vm.prank(bob);
        campaign.pledge{value: 6 ether}();
        assertEq(campaign.totalPledged(), 10 ether);
        assertEq(address(campaign).balance, 10 ether);
    }

    function test_Pledge_ZeroAmountReverts() public {
        campaign = _newCampaign();
        vm.prank(alice);
        vm.expectRevert(CrowdFundCampaign.ZeroPledge.selector);
        campaign.pledge{value: 0}();
    }

    function test_Pledge_CreatorCannotPledge() public {
        campaign = _newCampaign();
        vm.prank(creator);
        vm.expectRevert(CrowdFundCampaign.CreatorCannotPledge.selector);
        campaign.pledge{value: 1 ether}();
    }

    function test_Pledge_AfterDeadlineReverts() public {
        campaign = _newCampaign();
        vm.warp(block.timestamp + DURATION + 1);
        vm.prank(alice);
        vm.expectRevert(CrowdFundCampaign.CampaignEnded.selector);
        campaign.pledge{value: 1 ether}();
    }

    function test_Pledge_AtDeadlineBoundaryAllowed() public {
        campaign = _newCampaign();
        vm.warp(campaign.deadline());
        vm.prank(alice);
        campaign.pledge{value: 1 ether}();
        assertEq(campaign.totalPledged(), 1 ether);
    }

    /* ==================== STATUS ==================== */

    function test_Status_ActiveBeforeDeadline() public {
        campaign = _newCampaign();
        assertEq(uint256(campaign.status()), uint256(CrowdFundCampaign.Status.Active));
    }

    function test_Status_SuccessfulWhenGoalMet() public {
        campaign = _newCampaign();
        vm.prank(alice);
        campaign.pledge{value: GOAL}();
        vm.warp(block.timestamp + DURATION + 1);
        assertEq(uint256(campaign.status()), uint256(CrowdFundCampaign.Status.Successful));
    }

    function test_Status_FailedWhenGoalMissed() public {
        campaign = _newCampaign();
        vm.prank(alice);
        campaign.pledge{value: GOAL - 1}();
        vm.warp(block.timestamp + DURATION + 1);
        assertEq(uint256(campaign.status()), uint256(CrowdFundCampaign.Status.Failed));
    }

    /* ==================== SUCCESSFUL CLAIM ==================== */

    function test_Claim_SuccessPaysCreatorAndFee() public {
        campaign = _newCampaign();
        vm.prank(alice);
        campaign.pledge{value: 6 ether}();
        vm.prank(bob);
        campaign.pledge{value: 4 ether}();
        vm.warp(block.timestamp + DURATION + 1);

        uint256 creatorBefore = creator.balance;
        vm.expectEmit(true, false, true, true);
        emit Claimed(creator, 9.9 ether);
        vm.prank(creator);
        campaign.claim();

        assertEq(creator.balance - creatorBefore, 9.9 ether); // 10 ether - 1% fee
        assertEq(factory.accruedFees(), 0.1 ether);
        assertEq(address(campaign).balance, 0);
        assertTrue(campaign.claimed());
    }

    function test_Claim_BeforeDeadlineReverts() public {
        campaign = _newCampaign();
        vm.prank(alice);
        campaign.pledge{value: GOAL}();
        vm.prank(creator);
        vm.expectRevert(CrowdFundCampaign.DeadlineNotPassed.selector);
        campaign.claim();
    }

    function test_Claim_WhenGoalMissedReverts() public {
        campaign = _newCampaign();
        vm.prank(alice);
        campaign.pledge{value: GOAL - 1}();
        vm.warp(block.timestamp + DURATION + 1);
        vm.prank(creator);
        vm.expectRevert(CrowdFundCampaign.NotSuccessful.selector);
        campaign.claim();
    }

    function test_Claim_NonCreatorReverts() public {
        campaign = _newCampaign();
        vm.prank(alice);
        campaign.pledge{value: GOAL}();
        vm.warp(block.timestamp + DURATION + 1);
        vm.prank(alice);
        vm.expectRevert(CrowdFundCampaign.NotCreator.selector);
        campaign.claim();
    }

    function test_Claim_CannotClaimTwice() public {
        campaign = _newCampaign();
        vm.prank(alice);
        campaign.pledge{value: GOAL}();
        vm.warp(block.timestamp + DURATION + 1);
        vm.prank(creator);
        campaign.claim();
        vm.prank(creator);
        vm.expectRevert(CrowdFundCampaign.AlreadyClaimed.selector);
        campaign.claim();
    }

    function test_Fee_OwnerCanWithdrawAccruedFees() public {
        address treasury = makeAddr("treasury");
        campaign = _newCampaign();
        vm.prank(alice);
        campaign.pledge{value: GOAL}();
        vm.warp(block.timestamp + DURATION + 1);
        vm.prank(creator);
        campaign.claim();

        // The factory actually holds the fee ETH now (creditFees is payable).
        assertEq(address(factory).balance, 0.1 ether);
        factory.withdrawFees(payable(treasury));
        assertEq(treasury.balance, 0.1 ether);
        assertEq(factory.accruedFees(), 0);
    }

    /* ==================== REFUNDS ==================== */

    function test_Refund_FailedCampaignReturnsExactPledge() public {
        campaign = _newCampaign();
        vm.prank(alice);
        campaign.pledge{value: 3 ether}();
        vm.prank(bob);
        campaign.pledge{value: 2 ether}();
        vm.warp(block.timestamp + DURATION + 1);

        uint256 before = alice.balance;
        vm.expectEmit(true, false, true, true);
        emit Refunded(alice, 3 ether);
        vm.prank(alice);
        campaign.refund();

        assertEq(alice.balance - before, 3 ether);
        assertEq(campaign.pledged(alice), 0);
        assertEq(campaign.totalPledged(), 5 ether); // totals stay; entitlements zero out
    }

    function test_Refund_BeforeDeadlineReverts() public {
        campaign = _newCampaign();
        vm.prank(alice);
        campaign.pledge{value: 1 ether}();
        vm.prank(alice);
        vm.expectRevert(CrowdFundCampaign.DeadlineNotPassed.selector);
        campaign.refund();
    }

    function test_Refund_OnSuccessfulCampaignReverts() public {
        campaign = _newCampaign();
        vm.prank(alice);
        campaign.pledge{value: GOAL}();
        vm.warp(block.timestamp + DURATION + 1);
        vm.prank(alice);
        vm.expectRevert(CrowdFundCampaign.NotFailed.selector);
        campaign.refund();
    }

    function test_Refund_TwiceReverts() public {
        campaign = _newCampaign();
        vm.prank(alice);
        campaign.pledge{value: 1 ether}();
        vm.warp(block.timestamp + DURATION + 1);
        vm.prank(alice);
        campaign.refund();
        vm.prank(alice);
        vm.expectRevert(CrowdFundCampaign.NothingToRefund.selector);
        campaign.refund();
    }

    function test_Refund_NonBackerReverts() public {
        campaign = _newCampaign();
        vm.prank(alice);
        campaign.pledge{value: 1 ether}();
        vm.warp(block.timestamp + DURATION + 1);
        vm.prank(bob);
        vm.expectRevert(CrowdFundCampaign.NothingToRefund.selector);
        campaign.refund();
    }

    /* ==================== REENTRANCY ==================== */

    function test_Refund_ReentrancyBlocked() public {
        campaign = _newCampaign();
        ReentrantBacker attacker = new ReentrantBacker(campaign);
        vm.deal(address(attacker), 10 ether);

        vm.prank(address(attacker));
        campaign.pledge{value: 1 ether}();
        vm.warp(block.timestamp + DURATION + 1);

        // The re-entrant refund inside receive() reverts, which reverts the whole
        // transaction — so the attacker's entitlement is still intact (no double-dip).
        vm.expectRevert();
        attacker.attack();
        assertEq(campaign.pledged(address(attacker)), 1 ether);

        // The legitimate single refund then works.
        vm.prank(address(attacker));
        campaign.refund();
        assertEq(address(attacker).balance, 10 ether);
    }

    /* ==================== FUZZ ==================== */

    function testFuzz_RefundReturnsExactAmount(uint256 amount) public {
        amount = bound(amount, 1, GOAL - 1); // strictly below goal → always Failed
        campaign = _newCampaign();
        vm.prank(alice);
        campaign.pledge{value: amount}();
        vm.warp(block.timestamp + DURATION + 1);
        uint256 before = alice.balance;
        vm.prank(alice);
        campaign.refund();
        assertEq(alice.balance - before, amount);
        assertEq(address(campaign).balance, 0);
    }

    function testFuzz_ClaimPaysCreatorMinusFee(uint256 pledgedAmount) public {
        pledgedAmount = bound(pledgedAmount, GOAL, 100 ether);
        campaign = _newCampaign();
        vm.prank(alice);
        campaign.pledge{value: pledgedAmount}();
        vm.warp(block.timestamp + DURATION + 1);

        uint256 expectedPayout = pledgedAmount - (pledgedAmount * 100) / 10_000;
        uint256 creatorBefore = creator.balance;
        vm.prank(creator);
        campaign.claim();

        assertEq(creator.balance - creatorBefore, expectedPayout);
        assertEq(factory.accruedFees(), pledgedAmount - expectedPayout);
    }

    function testFuzz_FiveBackersEndToEnd(uint256 a, uint256 b, uint256 c, uint256 d, uint256 e) public {
        address[5] memory backers = [alice, bob, carol, makeAddr("dave"), makeAddr("erin")];
        uint256[5] memory amounts = [a, b, c, d, e];

        campaign = _newCampaign();
        uint256 sum;
        for (uint256 i = 0; i < 5; i++) {
            amounts[i] = bound(amounts[i], 0, 4 ether);
            vm.deal(backers[i], 10 ether);
            if (amounts[i] > 0) {
                vm.prank(backers[i]);
                campaign.pledge{value: amounts[i]}();
            }
            sum += amounts[i];
        }
        vm.warp(block.timestamp + DURATION + 1);

        if (sum >= GOAL) {
            vm.prank(creator);
            campaign.claim();
            assertEq(creator.balance, 100 ether + sum - (sum * 100) / 10_000);
            assertEq(address(campaign).balance, 0);
        } else {
            for (uint256 i = 0; i < 5; i++) {
                if (amounts[i] > 0) {
                    uint256 before = backers[i].balance;
                    vm.prank(backers[i]);
                    campaign.refund();
                    assertEq(backers[i].balance - before, amounts[i]);
                }
            }
            assertEq(address(campaign).balance, 0);
        }
    }
}
