// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TrustEscrow} from "../src/TrustEscrow.sol";
import {Ownable} from "../src/Ownable.sol";

/// @notice A seller contract that tries to re-enter `release` from its receive function.
contract MaliciousSeller {
    TrustEscrow escrow;
    uint256 dealId;
    bool attacking;

    constructor(TrustEscrow escrow_) {
        escrow = escrow_;
    }

    function setDealId(uint256 dealId_) external {
        dealId = dealId_;
    }

    function trigger() external {
        attacking = true;
        escrow.release(dealId);
    }

    receive() external payable {
        if (attacking) {
            attacking = false;
            escrow.release(dealId); // must revert thanks to the reentrancy guard
        }
    }
}

contract TrustEscrowTest is Test {
    TrustEscrow escrow;

    address owner = address(this);
    address buyer = makeAddr("buyer");
    address seller = makeAddr("seller");
    address arbiter = makeAddr("arbiter");
    address outsider = makeAddr("outsider");
    address treasury = makeAddr("treasury");

    uint256 constant FEE_BPS = 50; // 0.5%

    event DealOpened(
        uint256 indexed dealId, address indexed buyer, address indexed seller, address arbiter, uint256 amount
    );
    event DealReleased(uint256 indexed dealId, address indexed seller, uint256 amount);
    event DealRefunded(uint256 indexed dealId, address indexed buyer, uint256 amount);
    event DisputeRaised(uint256 indexed dealId, address indexed by);
    event DisputeResolved(
        uint256 indexed dealId, address indexed arbiter, uint256 buyerAmount, uint256 sellerAmount
    );
    event FeeCredited(uint256 amount);
    event FeeBpsUpdated(uint256 oldBps, uint256 newBps);

    function setUp() public {
        escrow = new TrustEscrow(FEE_BPS, owner);
        vm.deal(buyer, 10_000 ether); // generous balance for fuzz tests
        vm.deal(seller, 10 ether);
        vm.deal(arbiter, 10 ether);
    }

    /// Buyer opens a standard 10 ETH deal.
    function _openDeal() internal returns (uint256 dealId) {
        vm.prank(buyer);
        dealId = escrow.openDeal{value: 10 ether}(seller, arbiter);
    }

    /* ==================== OPEN ==================== */

    function test_OpenDeal_RecordsDealAndEmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit DealOpened(0, buyer, seller, arbiter, 10 ether);
        vm.prank(buyer);
        uint256 dealId = escrow.openDeal{value: 10 ether}(seller, arbiter);

        (address b, address s, address a, uint256 amount, TrustEscrow.DealState state) = escrow.deals(dealId);
        assertEq(b, buyer);
        assertEq(s, seller);
        assertEq(a, arbiter);
        assertEq(amount, 10 ether);
        assertEq(uint256(state), uint256(TrustEscrow.DealState.Active));
        assertEq(escrow.dealCount(), 1);
        assertEq(address(escrow).balance, 10 ether);
    }

    function test_OpenDeal_ZeroDepositReverts() public {
        vm.prank(buyer);
        vm.expectRevert(TrustEscrow.ZeroDeposit.selector);
        escrow.openDeal{value: 0}(seller, arbiter);
    }

    function test_OpenDeal_SellerCannotBeBuyer() public {
        vm.prank(buyer);
        vm.expectRevert(TrustEscrow.InvalidParties.selector);
        escrow.openDeal{value: 1 ether}(buyer, arbiter);
    }

    function test_OpenDeal_ArbiterCannotBeBuyerOrSeller() public {
        vm.prank(buyer);
        vm.expectRevert(TrustEscrow.InvalidParties.selector);
        escrow.openDeal{value: 1 ether}(seller, buyer);
        vm.prank(buyer);
        vm.expectRevert(TrustEscrow.InvalidParties.selector);
        escrow.openDeal{value: 1 ether}(seller, seller);
    }

    function test_OpenDeal_ZeroPartiesRevert() public {
        vm.prank(buyer);
        vm.expectRevert(TrustEscrow.InvalidParties.selector);
        escrow.openDeal{value: 1 ether}(address(0), arbiter);
        vm.prank(buyer);
        vm.expectRevert(TrustEscrow.InvalidParties.selector);
        escrow.openDeal{value: 1 ether}(seller, address(0));
    }

    /* ==================== RELEASE ==================== */

    function test_Release_SellerGetsDepositMinusFee() public {
        uint256 dealId = _openDeal();
        uint256 fee = (10 ether * FEE_BPS) / 10_000;

        uint256 sellerBefore = seller.balance;
        vm.expectEmit(true, true, true, true);
        emit DealReleased(dealId, seller, 10 ether - fee);
        vm.prank(seller);
        escrow.release(dealId);

        assertEq(seller.balance - sellerBefore, 10 ether - fee);
        assertEq(escrow.accruedFees(), fee);
        assertEq(address(escrow).balance, fee); // only the fee ETH remains, for the platform
        (, , , , TrustEscrow.DealState state) = escrow.deals(dealId);
        assertEq(uint256(state), uint256(TrustEscrow.DealState.Released));
    }

    function test_Release_OnlySeller() public {
        uint256 dealId = _openDeal();
        vm.prank(buyer);
        vm.expectRevert(TrustEscrow.NotSeller.selector);
        escrow.release(dealId);
        vm.prank(outsider);
        vm.expectRevert(TrustEscrow.NotSeller.selector);
        escrow.release(dealId);
    }

    function test_Release_TwiceReverts() public {
        uint256 dealId = _openDeal();
        vm.prank(seller);
        escrow.release(dealId);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(TrustEscrow.NotActive.selector, dealId));
        escrow.release(dealId);
    }

    function test_Release_AfterRefundReverts() public {
        uint256 dealId = _openDeal();
        vm.prank(buyer);
        escrow.refund(dealId);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(TrustEscrow.NotActive.selector, dealId));
        escrow.release(dealId);
    }

    /* ==================== REFUND ==================== */

    function test_Refund_BuyerGetsFullDepositNoFee() public {
        uint256 dealId = _openDeal();
        uint256 buyerBefore = buyer.balance;

        vm.expectEmit(true, true, true, true);
        emit DealRefunded(dealId, buyer, 10 ether);
        vm.prank(buyer);
        escrow.refund(dealId);

        assertEq(buyer.balance - buyerBefore, 10 ether);
        assertEq(escrow.accruedFees(), 0);
        assertEq(address(escrow).balance, 0);
        (, , , , TrustEscrow.DealState state) = escrow.deals(dealId);
        assertEq(uint256(state), uint256(TrustEscrow.DealState.Refunded));
    }

    function test_Refund_OnlyBuyer() public {
        uint256 dealId = _openDeal();
        vm.prank(seller);
        vm.expectRevert(TrustEscrow.NotBuyer.selector);
        escrow.refund(dealId);
    }

    function test_Refund_TwiceReverts() public {
        uint256 dealId = _openDeal();
        vm.prank(buyer);
        escrow.refund(dealId);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(TrustEscrow.NotActive.selector, dealId));
        escrow.refund(dealId);
    }

    /* ==================== DISPUTE ==================== */

    function test_Dispute_OnlyBuyerOrSeller() public {
        uint256 dealId = _openDeal();
        vm.expectEmit(true, true, false, true);
        emit DisputeRaised(dealId, buyer);
        vm.prank(buyer);
        escrow.dispute(dealId);
        (, , , , TrustEscrow.DealState state) = escrow.deals(dealId);
        assertEq(uint256(state), uint256(TrustEscrow.DealState.Disputed));
    }

    function test_Dispute_SellerCanAlsoRaise() public {
        uint256 dealId = _openDeal();
        vm.prank(seller);
        escrow.dispute(dealId);
        (, , , , TrustEscrow.DealState state) = escrow.deals(dealId);
        assertEq(uint256(state), uint256(TrustEscrow.DealState.Disputed));
    }

    function test_Dispute_OutsiderReverts() public {
        uint256 dealId = _openDeal();
        vm.prank(arbiter);
        vm.expectRevert(TrustEscrow.NotParty.selector);
        escrow.dispute(dealId);
        vm.prank(outsider);
        vm.expectRevert(TrustEscrow.NotParty.selector);
        escrow.dispute(dealId);
    }

    function test_Dispute_OnNonActiveReverts() public {
        uint256 dealId = _openDeal();
        vm.prank(seller);
        escrow.release(dealId);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(TrustEscrow.NotActive.selector, dealId));
        escrow.dispute(dealId);
    }

    function test_Dispute_FreezesReleaseAndRefund() public {
        uint256 dealId = _openDeal();
        vm.prank(buyer);
        escrow.dispute(dealId);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(TrustEscrow.NotActive.selector, dealId));
        escrow.release(dealId);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(TrustEscrow.NotActive.selector, dealId));
        escrow.refund(dealId);
    }

    /* ==================== RESOLVE ==================== */

    function test_Resolve_SplitsBetweenPartiesMinusFee() public {
        uint256 dealId = _openDeal();
        vm.prank(buyer);
        escrow.dispute(dealId);

        uint256 fee = (10 ether * FEE_BPS) / 10_000;
        uint256 buyerAmount = 4 ether;
        uint256 sellerAmount = 10 ether - fee - buyerAmount;

        uint256 buyerBefore = buyer.balance;
        uint256 sellerBefore = seller.balance;
        vm.expectEmit(true, true, true, true);
        emit DisputeResolved(dealId, arbiter, buyerAmount, sellerAmount);
        vm.prank(arbiter);
        escrow.resolve(dealId, buyerAmount);

        assertEq(buyer.balance - buyerBefore, buyerAmount);
        assertEq(seller.balance - sellerBefore, sellerAmount);
        assertEq(escrow.accruedFees(), fee);
        assertEq(address(escrow).balance, fee);
        (, , , , TrustEscrow.DealState state) = escrow.deals(dealId);
        assertEq(uint256(state), uint256(TrustEscrow.DealState.Resolved));
    }

    function test_Resolve_FullBuyerWin() public {
        uint256 dealId = _openDeal();
        vm.prank(buyer);
        escrow.dispute(dealId);
        uint256 fee = (10 ether * FEE_BPS) / 10_000;

        uint256 buyerBefore = buyer.balance;
        vm.prank(arbiter);
        escrow.resolve(dealId, 10 ether - fee); // buyer gets everything except the fee
        assertEq(buyer.balance - buyerBefore, 10 ether - fee);
        assertEq(seller.balance, 10 ether);
    }

    function test_Resolve_OnlyArbiter() public {
        uint256 dealId = _openDeal();
        vm.prank(buyer);
        escrow.dispute(dealId);
        vm.prank(buyer);
        vm.expectRevert(TrustEscrow.NotArbiter.selector);
        escrow.resolve(dealId, 5 ether);
    }

    function test_Resolve_OnNonDisputedReverts() public {
        uint256 dealId = _openDeal();
        vm.prank(arbiter);
        vm.expectRevert(abi.encodeWithSelector(TrustEscrow.NotDisputed.selector, dealId));
        escrow.resolve(dealId, 5 ether);
    }

    function test_Resolve_SplitTooLargeReverts() public {
        uint256 dealId = _openDeal();
        vm.prank(buyer);
        escrow.dispute(dealId);
        uint256 fee = (10 ether * FEE_BPS) / 10_000;
        vm.prank(arbiter);
        vm.expectRevert(
            abi.encodeWithSelector(TrustEscrow.InvalidSplit.selector, 10 ether - fee + 1, 10 ether - fee)
        );
        escrow.resolve(dealId, 10 ether - fee + 1);
    }

    function test_AfterResolve_ReleaseAndRefundRevert() public {
        uint256 dealId = _openDeal();
        vm.prank(buyer);
        escrow.dispute(dealId);
        vm.prank(arbiter);
        escrow.resolve(dealId, 5 ether);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(TrustEscrow.NotActive.selector, dealId));
        escrow.release(dealId);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(TrustEscrow.NotActive.selector, dealId));
        escrow.refund(dealId);
    }

    /* ==================== PLATFORM FEES ==================== */

    function test_WithdrawFees_OwnerGetsAccrued() public {
        uint256 dealId = _openDeal();
        vm.prank(seller);
        escrow.release(dealId);
        uint256 fee = (10 ether * FEE_BPS) / 10_000;

        escrow.withdrawFees(payable(treasury));
        assertEq(treasury.balance, fee);
        assertEq(escrow.accruedFees(), 0);
        assertEq(address(escrow).balance, 0);
    }

    function test_WithdrawFees_OnlyOwner() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.NotOwner.selector, outsider));
        escrow.withdrawFees(payable(outsider));
    }

    function test_SetFeeBps_OnlyOwnerAndCapped() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.NotOwner.selector, outsider));
        escrow.setFeeBps(100);
        vm.expectRevert(abi.encodeWithSelector(TrustEscrow.FeeTooHigh.selector, 1001, 1000));
        escrow.setFeeBps(1001);
        vm.expectEmit(false, false, true, true);
        emit FeeBpsUpdated(50, 100);
        escrow.setFeeBps(100);
        assertEq(escrow.feeBps(), 100);
    }

    /* ==================== REENTRANCY ==================== */

    function test_Release_ReentrancyBlocked() public {
        MaliciousSeller ms = new MaliciousSeller(escrow);
        vm.prank(buyer);
        uint256 dealId = escrow.openDeal{value: 10 ether}(address(ms), arbiter);
        ms.setDealId(dealId);

        // Trigger a release that re-enters release from receive() — the whole tx reverts
        // and the deal stays Active with funds intact.
        vm.prank(address(ms));
        vm.expectRevert();
        ms.trigger();
        (, , , , TrustEscrow.DealState state) = escrow.deals(dealId);
        assertEq(uint256(state), uint256(TrustEscrow.DealState.Active));
        assertEq(address(escrow).balance, 10 ether);

        // An honest release then works fine.
        vm.prank(address(ms));
        escrow.release(dealId);
        assertEq(address(ms).balance, 10 ether - (10 ether * FEE_BPS) / 10_000);
    }

    /* ==================== FUZZ ==================== */

    function testFuzz_ReleaseMath(uint256 amount) public {
        amount = bound(amount, 1, 1000 ether);
        vm.prank(buyer);
        uint256 dealId = escrow.openDeal{value: amount}(seller, arbiter);

        uint256 fee = (amount * FEE_BPS) / 10_000;
        uint256 sellerBefore = seller.balance;
        vm.prank(seller);
        escrow.release(dealId);

        assertEq(seller.balance - sellerBefore, amount - fee);
        assertEq(escrow.accruedFees(), fee);
        assertEq(address(escrow).balance, fee);
    }

    function testFuzz_ResolveMath(uint256 amount, uint256 buyerAmount) public {
        amount = bound(amount, 1, 1000 ether);
        vm.prank(buyer);
        uint256 dealId = escrow.openDeal{value: amount}(seller, arbiter);
        vm.prank(buyer);
        escrow.dispute(dealId);

        uint256 fee = (amount * FEE_BPS) / 10_000;
        buyerAmount = bound(buyerAmount, 0, amount - fee);

        uint256 buyerBefore = buyer.balance;
        uint256 sellerBefore = seller.balance;
        vm.prank(arbiter);
        escrow.resolve(dealId, buyerAmount);

        assertEq(buyer.balance - buyerBefore, buyerAmount);
        assertEq(seller.balance - sellerBefore, amount - fee - buyerAmount);
        assertEq(escrow.accruedFees(), fee);
        assertEq(address(escrow).balance, fee);
    }

    function testFuzz_ManyDeals_AccountingAlwaysBalances(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 1, 100 ether);
        b = bound(b, 1, 100 ether);
        c = bound(c, 1, 100 ether);

        address[3] memory sellers = [seller, makeAddr("seller2"), makeAddr("seller3")];
        uint256[3] memory amounts = [a, b, c];
        uint256 expectedFees;

        for (uint256 i = 0; i < 3; i++) {
            vm.prank(buyer);
            uint256 dealId = escrow.openDeal{value: amounts[i]}(sellers[i], arbiter);
            expectedFees += (amounts[i] * FEE_BPS) / 10_000;
            vm.prank(sellers[i]);
            escrow.release(dealId);
        }

        assertEq(escrow.accruedFees(), expectedFees);
        assertEq(address(escrow).balance, expectedFees); // every non-fee wei has left the contract
    }
}
