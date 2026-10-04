// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {SahmFixture} from "./SahmFixture.sol";
import {SahmOrderBook} from "../src/SahmOrderBook.sol";
import {SahmAMM} from "../src/SahmAMM.sol";
import {SahmMargin} from "../src/SahmMargin.sol";
import {SahmInsuranceFund} from "../src/SahmInsuranceFund.sol";
import {SahmGovernor} from "../src/SahmGovernor.sol";

contract SahmOrderBookTest is SahmFixture {
    function _placeAsk(uint256 price, uint256 amount) internal returns (uint256) {
        vm.prank(traderA);
        return book.placeAsk(address(stable), price, amount);
    }

    function test_PlaceAsk_EscrowsTokens() public {
        _placeAsk(2_000 ether, 5 ether);
        assertEq(stable.balanceOf(address(book)), 5 ether);
        ( , , , , uint256 amount, bool active) = book.orders(0);
        assertEq(amount, 5 ether);
        assertTrue(active);
    }

    function test_Buy_FillsAskWithFees() public {
        _placeAsk(2_000 ether, 5 ether);
        uint256 before = stable.balanceOf(traderB);
        vm.prank(traderB);
        book.buy(0, 5 ether);
        // cost = 10,000; taker fee 0.2% = 20; traderB receives the 5 tokens back
        assertEq(before - stable.balanceOf(traderB), 10_020 ether - 5 ether);
        assertEq(stable.balanceOf(traderA), 900_000 ether - 5 ether + 9_990 ether); // −100k margin deposit, −5 escrow
        assertEq(treasury.totalFeesCollected(), 30 ether);
        ( , , , , uint256 remaining, bool active) = book.orders(0);
        assertEq(remaining, 0);
        assertFalse(active);
    }

    function test_SelfFill_Rejected() public {
        _placeAsk(2_000 ether, 5 ether);
        vm.prank(traderA);
        vm.expectRevert(abi.encodeWithSelector(SahmOrderBook.SelfFill.selector, traderA));
        book.buy(0, 1 ether);
    }

    function test_Cancel_RefundsEscrow() public {
        _placeAsk(2_000 ether, 5 ether);
        uint256 before = stable.balanceOf(traderA);
        vm.prank(traderA);
        book.cancelOrder(0);
        assertEq(stable.balanceOf(traderA) - before, 5 ether);
    }

    function test_Bid_EscrowsQuote() public {
        vm.prank(traderB);
        uint256 id = book.placeBid(address(stable), 2_000 ether, 5 ether);
        assertEq(collateral.lockedMargin(traderB), 10_000 ether);
        vm.prank(traderB);
        book.cancelOrder(id);
        assertEq(collateral.lockedMargin(traderB), 0);
    }

    function test_Sell_FillsBid() public {
        vm.prank(traderB);
        uint256 id = book.placeBid(address(stable), 2_000 ether, 5 ether);
        uint256 before = stable.balanceOf(traderA);
        vm.prank(traderA);
        book.sell(id, 5 ether);
        // traderA sells 5 tokens, receives 10,000 − 20 fee
        assertEq(stable.balanceOf(traderA) - before, 9_980 ether - 5 ether); // minus the 5 tokens delivered
    }

    function test_Fill_OverAmountReverts() public {
        _placeAsk(2_000 ether, 5 ether);
        vm.prank(traderB);
        vm.expectRevert();
        book.buy(0, 6 ether);
    }

    function test_Fill_RequiresKyc() public {
        _placeAsk(2_000 ether, 5 ether);
        vm.prank(outsider);
        vm.expectRevert();
        book.buy(0, 1 ether);
    }
}

contract SahmAMMTest is SahmFixture {
    function test_AddLiquidity_MintsShares() public {
        uint256 before = amm.lpBalance(poolId, lp);
        vm.prank(lp);
        uint256 shares = amm.addLiquidity(poolId, 10 ether, 20_000 ether);
        assertEq(shares, 20_000 ether);
        assertEq(amm.lpBalance(poolId, lp) - before, 20_000 ether);
    }

    function test_SwapQuoteForToken() public {
        // buy 1 token: 10×20,000 = 200,000 = k; q = 2,000 → out = 10 − 200,000/22,000
        uint256 before = stable.balanceOf(traderA);
        vm.prank(traderA);
        uint256 out = amm.swapQuoteForToken(poolId, 2_000 ether, 0);
        // the pool token is the same stable: the trader receives `out` back
        assertEq(before - stable.balanceOf(traderA), 2_000 ether - out);
        uint256 expected = 10 ether - (uint256(10 ether) * uint256(20_000 ether)) / (uint256(20_000 ether) + uint256(1_994 ether));
        assertEq(out, expected);
    }

    function test_Swap_SlippageReverts() public {
        vm.prank(traderA);
        vm.expectRevert();
        amm.swapQuoteForToken(poolId, 2_000 ether, 9 ether); // demands too much
    }

    function test_SwapTokenForQuote_Fees() public {
        uint256 before = stable.balanceOf(traderA);
        vm.prank(traderA);
        amm.swapTokenForQuote(poolId, 5 ether, 0);
        assertTrue(stable.balanceOf(traderA) > before);
        assertTrue(treasury.totalFeesCollected() > 0);
    }

    function test_RemoveLiquidity_Proportional() public {
        uint256 before = stable.balanceOf(lp);
        vm.prank(lp);
        amm.removeLiquidity(poolId, 10_000 ether); // half
        assertEq(stable.balanceOf(lp) - before, 10_000 ether + 5 ether);
    }

    function test_K_Invariant_Holds() public {
        vm.prank(traderA);
        amm.swapQuoteForToken(poolId, 1_000 ether, 0);
        vm.prank(traderA);
        amm.swapTokenForQuote(poolId, 1 ether, 0);
        ( , uint256 rt, uint256 rq, , ) = amm.pools(poolId);
        assertTrue(rt * rq >= 10 * 20_000 ether);
    }
}

contract SahmMarginTest is SahmFixture {
    function test_OpenLong_LocksMargin() public {
        uint256 id = _openLong(traderA, 5_000 ether, 200); // 2x → 10,000 notional
        assertEq(collateral.lockedMargin(traderA), 5_000 ether);
        ( , , SahmMargin.Direction dir, uint256 m, uint256 notional, , , , bool open) = margin.positions(id);
        assertEq(uint8(dir), uint8(SahmMargin.Direction.Long));
        assertEq(m, 5_000 ether);
        assertEq(notional, 10_000 ether);
        assertTrue(open);
    }

    function test_Open_LeverageLimit() public {
        vm.prank(traderA);
        vm.expectRevert();
        margin.openPosition(address(stable), SahmMargin.Direction.Long, 1 ether, 600); // 6x > 5x
    }

    function test_CloseLong_Profits() public {
        uint256 id = _openLong(traderA, 5_000 ether, 200); // entry 2,000
        vm.warp(block.timestamp + 1 hours + 1);
        oracle.postPrice(address(stable), 2_200 ether);
        uint256 before = stable.balanceOf(traderA);
        vm.prank(traderA);
        margin.closePosition(id);
        // pnl = (2,200−2,000)/2,000 × 10,000 = 1,000
        assertEq(stable.balanceOf(traderA) - before, 1_000 ether);
        assertEq(collateral.lockedMargin(traderA), 0);
    }

    function test_CloseShort_ProfitsOnDrop() public {
        vm.prank(traderA);
        uint256 id = margin.openPosition(address(stable), SahmMargin.Direction.Short, 5_000 ether, 200);
        vm.warp(block.timestamp + 1 hours + 1);
        oracle.postPrice(address(stable), 1_800 ether);
        uint256 before = stable.balanceOf(traderA);
        vm.prank(traderA);
        margin.closePosition(id);
        assertEq(stable.balanceOf(traderA) - before, 1_000 ether);
    }

    function test_Liquidation_BelowMaintenance() public {
        uint256 id = _openLong(traderA, 5_000 ether, 400); // 4x → 20,000 notional
        // crash: 2,000 → 1,900 → loss = 5% × 20,000 = 1,000 → equity 4,000 = 20% ≥ 1% still fine
        // crash harder: 2,000 → 1,600 → loss 20% → equity 1,000 = 5% — still above 1%
        // 2,000 → 1,100 → loss 45% → equity negative → liquidatable
        vm.warp(block.timestamp + 1 hours + 1);
        oracle.postPrice(address(stable), 1_100 ether);
        vm.prank(liquidator);
        margin.liquidate(id);
        ( , , , , , , , , bool open) = margin.positions(id);
        assertFalse(open);
    }

    function test_Liquidate_HealthyReverts() public {
        uint256 id = _openLong(traderA, 5_000 ether, 200);
        vm.prank(liquidator);
        vm.expectRevert();
        margin.liquidate(id);
    }

    function test_Close_NotTraderReverts() public {
        uint256 id = _openLong(traderA, 5_000 ether, 200);
        vm.prank(outsider);
        vm.expectRevert();
        margin.closePosition(id);
    }
}

contract SahmInsuranceTest is SahmFixture {
    function test_FundAndClaim() public {
        stable.mint(address(this), 10_000 ether);
        stable.approve(address(insurance), 5_000 ether);
        insurance.donate(5_000 ether);
        uint256 claimId = insurance.fileClaim(1_000 ether, "liquidation shortfall");
        vm.prank(officer);
        insurance.voteClaim(claimId, true);
        insurance.voteClaim(claimId, true);
        ( , uint256 amount, , , , bool decided, bool approved) = insurance.claims(claimId);
        assertEq(amount, 1_000 ether);
        assertTrue(decided);
        assertTrue(approved);
        assertEq(stable.balanceOf(address(this)), 10_000 ether - 5_000 ether + 1_000 ether);
    }

    function test_Claim_Insufficient() public {
        uint256 claimId = insurance.fileClaim(100 ether, "no funds");
        vm.prank(officer);
        insurance.voteClaim(claimId, true);
        vm.expectRevert(abi.encodeWithSelector(SahmInsuranceFund.InsufficientFund.selector, 0, 100 ether));
        insurance.voteClaim(claimId, true);
    }

    function test_Vote_CommitteeOnly() public {
        uint256 claimId = insurance.fileClaim(1 ether, "x");
        vm.prank(outsider);
        vm.expectRevert();
        insurance.voteClaim(claimId, true);
    }
}

contract SahmGovernorTest is SahmFixture {
    function test_Propose_LpWeightedVote() public {
        vm.prank(lp);
        uint256 id = governor.propose(address(amm), 0, abi.encodeCall(amm.setFees, (50, 2000)), "raise fee to 0.5%");
        vm.warp(block.timestamp + 3 days);
        vm.prank(lp);
        governor.vote(id, true);
        ( , , , , , uint256 forV, , , , , , , ) = governor.proposals(id);
        assertEq(forV, 20_000 ether); // LP shares
    }

    function test_FullLifecycle_ChangesFee() public {
        vm.prank(lp);
        uint256 id = governor.propose(address(amm), 0, abi.encodeCall(amm.setFees, (50, 2000)), "raise fee");
        vm.warp(block.timestamp + 3 days);
        vm.prank(lp);
        governor.vote(id, true);
        vm.warp(block.timestamp + 10 days);
        assertEq(governor.state(id), 3);
        governor.execute(id);
        assertEq(governor.state(id), 4);
        assertEq(amm.feeBps(), 50);
    }

    function test_Defeated_UnderQuorum() public {
        vm.prank(lp);
        uint256 id = governor.propose(address(amm), 0, abi.encodeCall(amm.setFees, (50, 2000)), "unpopular");
        vm.warp(block.timestamp + 3 days);
        vm.warp(block.timestamp + 10 days);
        assertEq(governor.state(id), 5);
    }

    function test_InvalidTarget_Rejected() public {
        vm.expectRevert(SahmGovernor.InvalidTargets.selector);
        governor.propose(address(0xDEAD), 0, hex"1234", "escape");
    }

    function test_Timelock_BlocksEarly() public {
        vm.prank(lp);
        uint256 id = governor.propose(address(amm), 0, abi.encodeCall(amm.setFees, (50, 2000)), "timelocked");
        vm.warp(block.timestamp + 3 days);
        vm.prank(lp);
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
        vm.expectRevert(SahmGovernor.ProtocolPaused.selector);
        governor.propose(address(amm), 0, hex"1234", "paused");
    }
}
