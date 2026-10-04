// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {TamweelFixture} from "./TamweelFixture.sol";
import {TamweelMarkets} from "../src/TamweelMarkets.sol";
import {TamweelLoans} from "../src/TamweelLoans.sol";
import {TamweelCollateral} from "../src/TamweelCollateral.sol";
import {TamweelInsuranceFund} from "../src/TamweelInsuranceFund.sol";
import {TamweelGovernor} from "../src/TamweelGovernor.sol";

contract TamweelMarketsTest is TamweelFixture {
    function test_Supply_EscrowsCollateral() public {
        vm.prank(borrower);
        markets.supply(marketId, 10 ether);
        assertEq(markets.collateral(marketId, borrower), 10 ether);
        assertEq(stable.balanceOf(address(markets)), 10 ether);
    }

    function test_Borrow_WithinLtv() public {
        uint256 before = stable.balanceOf(borrower);
        _supplyAndBorrow(10 ether, 14_000 ether); // 20,000 value × 70% = 14,000 max
        assertEq(markets.debt(marketId, borrower), 14_000 ether);
        assertEq(stable.balanceOf(borrower) - before, 14_000 ether - 10 ether);
    }

    function test_Borrow_ExceedsLtvReverts() public {
        vm.prank(borrower);
        markets.supply(marketId, 10 ether);
        vm.prank(borrower);
        vm.expectRevert();
        markets.borrow(marketId, 15_000 ether);
    }

    function test_Repay_ReducesDebt() public {
        _supplyAndBorrow(10 ether, 14_000 ether);
        uint256 before = stable.balanceOf(borrower);
        vm.prank(borrower);
        markets.repay(marketId, 4_000 ether);
        assertEq(before - stable.balanceOf(borrower), 4_000 ether);
        assertEq(markets.debtOf(marketId, borrower), 10_000 ether);
    }

    function test_Withdraw_UnhealthyReverts() public {
        _supplyAndBorrow(10 ether, 14_000 ether);
        vm.prank(borrower);
        vm.expectRevert();
        markets.withdraw(marketId, 4 ether); // 6 left → 12,000 value < 14,000 debt
    }

    function test_InterestAccrues() public {
        _supplyAndBorrow(10 ether, 14_000 ether);
        uint256 debtBefore = markets.debtOf(marketId, borrower);
        vm.warp(block.timestamp + 30 days);
        markets.accrueInterest(marketId);
        uint256 debtAfter = markets.debtOf(marketId, borrower);
        assertTrue(debtAfter > debtBefore);
    }

    function test_Liquidation_SeizesAndAuctions() public {
        _supplyAndBorrow(10 ether, 14_000 ether);
        // price crash: 1 ETH = 1,500 → value 15,000 × 80% = 12,000 < 14,000 debt
        oracle.postPrice(address(stable), 1_500 ether);
        vm.warp(block.timestamp + 1 hours + 1);
        oracle.postPrice(address(stable), 1_500 ether);
        vm.warp(block.timestamp + 1 hours + 1);
        uint256 owed = markets.debtOf(marketId, borrower);
        uint256 liquidatorBefore = stable.balanceOf(liquidator);
        vm.prank(liquidator);
        markets.liquidate(marketId, borrower);
        assertTrue(liquidatorBefore - stable.balanceOf(liquidator) >= owed); // interest may accrue in-flight
        assertEq(markets.collateral(marketId, borrower), 0);
        assertEq(markets.debtOf(marketId, borrower), 0);
        ( , , , uint256 seizedAmount, , , , , ) = collateral.auctions(0);
        assertEq(seizedAmount, 10 ether);
    }

    function test_Liquidation_HealthyReverts() public {
        _supplyAndBorrow(10 ether, 14_000 ether);
        vm.prank(liquidator);
        vm.expectRevert();
        markets.liquidate(marketId, borrower);
    }

    function test_Borrow_RequiresKyc() public {
        vm.prank(outsider);
        vm.expectRevert();
        markets.borrow(marketId, 1 ether);
    }
}

contract TamweelCollateralTest is TamweelFixture {
    function test_Auction_DutchDecay() public {
        _supplyAndBorrow(10 ether, 14_000 ether);
        oracle.postPrice(address(stable), 1_500 ether);
        vm.warp(block.timestamp + 1 hours + 1);
        oracle.postPrice(address(stable), 1_500 ether);
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(liquidator);
        markets.liquidate(marketId, borrower);

        uint256 start = collateral.currentPrice(0);
        vm.warp(block.timestamp + 12 hours);
        uint256 mid = collateral.currentPrice(0);
        assertTrue(mid < start);

        vm.warp(block.timestamp + 1 days);
        ( , , , , , uint256 floorPrice, , , ) = collateral.auctions(0);
        assertEq(collateral.currentPrice(0), floorPrice);
    }

    function test_Auction_BidSettles() public {
        _supplyAndBorrow(10 ether, 14_000 ether);
        oracle.postPrice(address(stable), 1_500 ether);
        vm.warp(block.timestamp + 1 hours + 1);
        oracle.postPrice(address(stable), 1_500 ether);
        vm.warp(block.timestamp + 1 hours + 1);
        uint256 owed = markets.debtOf(marketId, borrower);
        vm.prank(liquidator);
        markets.liquidate(marketId, borrower);

        uint256 price = collateral.currentPrice(0);
        uint256 cost = (10 ether * price) / 1e18;
        vm.prank(borrower);
        collateral.bid(0);
        ( , , address beneficiary, uint256 amount, , , , , bool settled) = collateral.auctions(0);
        assertEq(beneficiary, liquidator);
        assertEq(amount, 10 ether);
        assertTrue(settled);
        assertTrue(stable.balanceOf(liquidator) <= 1_000_000 ether - owed + cost + 1 ether);
    }

    function test_Auction_AlreadySettledReverts() public {
        _supplyAndBorrow(10 ether, 14_000 ether);
        oracle.postPrice(address(stable), 1_500 ether);
        vm.warp(block.timestamp + 1 hours + 1);
        oracle.postPrice(address(stable), 1_500 ether);
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(liquidator);
        markets.liquidate(marketId, borrower);
        vm.prank(borrower);
        collateral.bid(0);
        vm.prank(borrower);
        vm.expectRevert();
        collateral.bid(0);
    }

    function test_SetAccepted_AdminOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        collateral.setAccepted(outsider, true);
    }
}

contract TamweelLoansTest is TamweelFixture {
    function _requestLoan() internal returns (uint256) {
        vm.prank(borrower);
        return loans.requestLoan(10_000 ether, 10, 30 days, "working capital");
    }

    function test_Request_CreditScoreGated() public {
        vm.prank(outsider); // no KYC / no score
        vm.expectRevert();
        loans.requestLoan(1_000 ether, 4, 30 days, "x");
    }

    function test_Lifecycle_DisburseAndRepay() public {
        uint256 id = _requestLoan();
        vm.prank(committee1);
        loans.approveLoan(id);
        uint256 before = stable.balanceOf(borrower);
        loans.disburse(id);
        assertEq(stable.balanceOf(borrower) - before, 10_000 ether);

        vm.prank(borrower);
        loans.payInstallment(id);
        ( , , , uint256 instAmt, uint256 total, uint256 paid, , , , , , TamweelLoans.Status status) = loans.loans(id);
        assertEq(instAmt, 1_050 ether); // (10,000 + 500) / 10
        assertEq(paid, 1);
        assertEq(uint8(status), uint8(TamweelLoans.Status.Active));
    }

    function test_LateFee_GoesToCharity() public {
        uint256 id = _requestLoan();
        vm.prank(committee1);
        loans.approveLoan(id);
        loans.disburse(id);
        vm.warp(block.timestamp + 61 days); // two installments due
        uint256 charityBefore = stable.balanceOf(charity);
        vm.prank(borrower);
        loans.payInstallment(id);
        // fee = 1,050 × 2% × 2 = 42
        assertEq(stable.balanceOf(charity) - charityBefore, 42 ether);
        ( , , , , , uint256 paid, , , , , , ) = loans.loans(id);
        assertEq(paid, 3);
    }

    function test_EarlySettlement_Rebate() public {
        uint256 id = _requestLoan();
        vm.prank(committee1);
        loans.approveLoan(id);
        loans.disburse(id);
        vm.prank(borrower);
        loans.payInstallment(id);
        uint256 before = stable.balanceOf(borrower);
        vm.prank(borrower);
        loans.settleEarly(id);
        // remaining 9 × 1,050 = 9,450; remaining interest = 450; rebate 5% = 22.5
        assertEq(before - stable.balanceOf(borrower), 9_450 ether - 225 ether / 10);
        ( , , , , , , , , , uint256 rebate, , TamweelLoans.Status status) = loans.loans(id);
        assertTrue(rebate > 0);
        assertEq(uint8(status), uint8(TamweelLoans.Status.Settled));
    }

    function test_Default_AfterMaxMissed() public {
        uint256 id = _requestLoan();
        vm.prank(committee1);
        loans.approveLoan(id);
        loans.disburse(id);
        vm.prank(borrower);
        loans.payInstallment(id);
        vm.warp(block.timestamp + 151 days); // 5 due, 4 missed > 2 max
        loans.markDefault(id);
        ( , , , , , , , , , , , TamweelLoans.Status status) = loans.loans(id);
        assertEq(uint8(status), uint8(TamweelLoans.Status.Defaulted));
    }

    function test_Default_NotYetReverts() public {
        uint256 id = _requestLoan();
        vm.prank(committee1);
        loans.approveLoan(id);
        loans.disburse(id);
        vm.expectRevert(TamweelLoans.NoInstallmentsDue.selector);
        loans.markDefault(id);
    }

    function test_Approve_CommitteeOnly() public {
        uint256 id = _requestLoan();
        vm.prank(outsider);
        vm.expectRevert();
        loans.approveLoan(id);
    }

    function test_Recover_FinancierOnly() public {
        uint256 id = _requestLoan();
        vm.prank(committee1);
        loans.approveLoan(id);
        loans.disburse(id);
        vm.prank(outsider);
        vm.expectRevert();
        loans.recover(id, outsider, 1 ether);
    }
}

contract TamweelInsuranceTest is TamweelFixture {
    function test_FundAndClaim_TwoOfThree() public {
        stable.mint(operator, 10_000 ether);
        stable.approve(address(insurance), 10_000 ether);
        insurance.donate(10_000 ether);

        uint256 claimId = insurance.fileClaim(marketId, 3_000 ether, "bad debt from liquidation shortfall");
        vm.prank(committee1);
        insurance.voteClaim(claimId, true);
        assertEq(vault.totalAssets(), 100_000 ether); // not yet injected

        vm.prank(committee2);
        insurance.voteClaim(claimId, true);
        assertEq(vault.totalAssets(), 103_000 ether); // coverage injected
        assertEq(insurance.totalPaidOut(), 3_000 ether);
    }

    function test_Claim_InsufficientFund() public {
        uint256 claimId = insurance.fileClaim(marketId, 100 ether, "no fund");
        vm.prank(committee1);
        insurance.voteClaim(claimId, true);
        vm.prank(committee2);
        vm.expectRevert(abi.encodeWithSelector(TamweelInsuranceFund.InsufficientFund.selector, 0, 100 ether));
        insurance.voteClaim(claimId, true);
    }

    function test_Vote_CommitteeOnly() public {
        uint256 claimId = insurance.fileClaim(marketId, 1 ether, "x");
        vm.prank(outsider);
        vm.expectRevert();
        insurance.voteClaim(claimId, true);
    }
}

contract TamweelGovernorTest is TamweelFixture {
    function test_Propose_VaultShareWeightedVote() public {
        vm.prank(depositor);
        uint256 id = governor.propose(address(loans), 0, abi.encodeCall(loans.setLoanInterestBps, (600)), "raise loan rate to 6%");
        vm.warp(block.timestamp + 3 days);
        vm.prank(depositor);
        governor.vote(id, true);
        ( , , , , , uint256 forV, , , , , , , ) = governor.proposals(id);
        assertEq(forV, 100_000 ether); // depositor's shares
    }

    function test_FullLifecycle_ChangesRate() public {
        vm.prank(depositor);
        uint256 id = governor.propose(address(loans), 0, abi.encodeCall(loans.setLoanInterestBps, (600)), "raise loan rate to 6%");
        vm.warp(block.timestamp + 3 days);
        vm.prank(depositor);
        governor.vote(id, true);
        vm.warp(block.timestamp + 10 days);
        assertEq(governor.state(id), 3);
        governor.execute(id);
        assertEq(governor.state(id), 4);
        assertEq(loans.loanInterestBps(), 600);
    }

    function test_Defeated_UnderQuorum() public {
        vm.prank(depositor);
        uint256 id = governor.propose(address(loans), 0, abi.encodeCall(loans.setLoanInterestBps, (600)), "unpopular");
        vm.warp(block.timestamp + 3 days);
        // no votes at all
        vm.warp(block.timestamp + 10 days);
        assertEq(governor.state(id), 5);
    }

    function test_InvalidTarget_Rejected() public {
        vm.expectRevert(TamweelGovernor.InvalidTargets.selector);
        governor.propose(address(0xDEAD), 0, hex"1234", "escape");
    }

    function test_Timelock_BlocksEarly() public {
        vm.prank(depositor);
        uint256 id = governor.propose(address(loans), 0, abi.encodeCall(loans.setLoanInterestBps, (600)), "timelocked");
        vm.warp(block.timestamp + 3 days);
        vm.prank(depositor);
        governor.vote(id, true);
        vm.warp(block.timestamp + 5 days); // t0+8d: inside the timelock
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
        vm.expectRevert(TamweelGovernor.ProtocolPaused.selector);
        governor.propose(address(loans), 0, hex"1234", "paused");
    }
}
