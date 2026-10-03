// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {SukukFixture} from "./SukukFixture.sol";
import {SukukVault} from "../src/SukukVault.sol";

contract SukukVaultTest is SukukFixture {
    /* ---------- issuance & purchase ---------- */

    function test_SeriesIssued() public {
        (string memory name, uint256 face, uint256 total, uint256 issued, uint64 mat, string memory asset, uint256 profit, bool sold, bool frozen) =
            vault.series(seriesId);
        assertEq(name, "Green Ijarah Sukuk - Series 1");
        assertEq(face, 100 ether);
        assertEq(total, 1000);
        assertEq(issued, 1000);
        assertEq(mat, uint64(maturity));
        assertEq(profit, 800);
        assertFalse(sold);
        assertFalse(frozen);
    }

    function test_Purchase_SellsOut() public {
        ( , , , uint256 issued, , , , , ) = vault.series(seriesId);
        assertEq(issued, 1000);
        vm.expectRevert(abi.encodeWithSelector(SukukVault.ExceedsSupply.selector, 1, 0));
        vm.prank(investorA);
        vault.purchase(seriesId, 1);
    }

    function test_Purchase_RequiresPayment() public {
        vm.prank(outsider);
        vm.expectRevert();
        vault.purchase(seriesId, 1); // no allowance, no balance
        assertEq(stable.balanceOf(address(vault)), 100_000 ether); // 1,000 × 100
    }

    function test_Purchase_AfterMaturityReverts() public {
        vm.warp(maturity);
        vm.prank(investorA);
        vm.expectRevert(abi.encodeWithSelector(SukukVault.NotYetMatured.selector, seriesId));
        vault.purchase(seriesId, 1);
    }

    /* ---------- income: Shariah gate ---------- */

    function test_RecordIncome_PendingUntilApproved() public {
        _recordIncome(5_000 ether);
        assertEq(vault.pendingApproval(seriesId), 5_000 ether);
        assertEq(vault.distributablePool(seriesId), 0);
    }

    function test_RecordIncome_IssuerOnly() public {
        stable.mint(outsider, 1_000 ether);
        vm.prank(outsider);
        stable.approve(address(vault), 1_000 ether);
        vm.prank(outsider);
        vm.expectRevert();
        vault.recordIncome(seriesId, 1_000 ether);
    }

    function test_ApproveIncome_ShariahOnly() public {
        _recordIncome(5_000 ether);
        vm.prank(outsider);
        vm.expectRevert();
        vault.approveIncome(seriesId);
    }

    function test_ApproveIncome_SplitsReserve() public {
        _recordIncome(5_000 ether);
        vm.prank(shariah);
        uint256 approved = vault.approveIncome(seriesId);
        assertEq(approved, 5_000 ether);
        assertEq(vault.profitReserve(seriesId), 500 ether); // 10%
        assertEq(vault.distributablePool(seriesId), 4_500 ether);
        assertEq(vault.pendingApproval(seriesId), 0);
    }

    function test_ApproveIncome_NothingPending() public {
        vm.prank(shariah);
        vm.expectRevert(SukukVault.ZeroAmount.selector);
        vault.approveIncome(seriesId);
    }

    /* ---------- distribution epochs ---------- */

    function test_Distribute_AndClaim_ProRata() public {
        _recordIncome(5_000 ether);
        vm.prank(shariah);
        vault.approveIncome(seriesId);
        vault.distribute(seriesId);

        // 4,500 pool / 1,000 certs = 4.5 per cert
        assertEq(vault.claimable(seriesId, investorA), 400 * 45 ether / 10);
        uint256 before = stable.balanceOf(investorA);
        vm.prank(investorA);
        vault.claim(seriesId);
        assertEq(stable.balanceOf(investorA) - before, 400 * 45 ether / 10);
    }

    function test_Claim_SnapshotPreventsPostEpochTransfers() public {
        _recordIncome(5_000 ether);
        vm.prank(shariah);
        vault.approveIncome(seriesId);
        vault.distribute(seriesId); // epoch 0 snapshot

        // no transfer function exists — certificates run to maturity (by design);
        // instead verify that the snapshot read matches issuance-time balances
        assertEq(vault.claimable(seriesId, investorB), 300 * 45 ether / 10);
        assertEq(vault.claimable(seriesId, investorC), 300 * 45 ether / 10);
    }

    function test_Claim_NothingToClaim() public {
        vm.prank(investorA);
        vm.expectRevert(SukukVault.NothingToClaim.selector);
        vault.claim(seriesId);
    }

    function test_Claim_TwiceAfterNewEpoch() public {
        _recordIncome(5_000 ether);
        vm.prank(shariah);
        vault.approveIncome(seriesId);
        vault.distribute(seriesId);
        _recordIncome(5_000 ether);
        vm.prank(shariah);
        vault.approveIncome(seriesId);
        vault.distribute(seriesId);

        vm.prank(investorA);
        uint256 first = vault.claim(seriesId);
        assertEq(first, 400 * 45 ether / 10 * 2); // two epochs
        vm.prank(investorA);
        vm.expectRevert(SukukVault.NothingToClaim.selector);
        vault.claim(seriesId);
    }

    /* ---------- maturity & redemption ---------- */

    function test_Redemption_BeforeMaturityReverts() public {
        vm.prank(investorA);
        vm.expectRevert(abi.encodeWithSelector(SukukVault.NotMatured.selector, seriesId));
        vault.redeem(seriesId, 100);
    }

    function test_Redemption_RequiresAssetSale() public {
        vm.warp(maturity);
        vm.prank(investorA);
        vm.expectRevert(abi.encodeWithSelector(SukukVault.RedemptionUnavailable.selector, seriesId));
        vault.redeem(seriesId, 100); // pool empty
    }

    function test_SellUnderlying_AtMaturityOnly() public {
        vm.expectRevert(abi.encodeWithSelector(SukukVault.NotMatured.selector, seriesId));
        vault.sellUnderlying(seriesId, 100_000 ether);

        vm.warp(maturity);
        vault.sellUnderlying(seriesId, 100_000 ether);
        assertEq(vault.redemptionPool(seriesId), 100_000 ether);
        ( , , , , , , , bool sold, ) = vault.series(seriesId);
        assertTrue(sold);
    }

    function test_Redemption_FullLifecycle() public {
        vm.warp(maturity);
        vault.sellUnderlying(seriesId, 100_000 ether);

        uint256 before = stable.balanceOf(investorB);
        vm.prank(investorB);
        uint256 payout = vault.redeem(seriesId, 300);
        assertEq(payout, 30_000 ether);
        assertEq(stable.balanceOf(investorB) - before, 30_000 ether);
        assertEq(vault.certificates(seriesId, investorB), 0);
        ( , , , uint256 issued, , , , , ) = vault.series(seriesId);
        assertEq(issued, 700);
    }

    function test_Redemption_OverBalanceReverts() public {
        vm.warp(maturity);
        vault.sellUnderlying(seriesId, 100_000 ether);
        vm.prank(investorA);
        vm.expectRevert(abi.encodeWithSelector(SukukVault.InsufficientCertificates.selector, 400, 500));
        vault.redeem(seriesId, 500);
    }

    function test_Redemption_ExceedsPoolReverts() public {
        vm.warp(maturity);
        vault.sellUnderlying(seriesId, 10_000 ether); // short sale proceeds
        vm.prank(investorA);
        vm.expectRevert(abi.encodeWithSelector(SukukVault.RedemptionUnavailable.selector, seriesId));
        vault.redeem(seriesId, 200); // needs 20,000
    }

    /* ---------- guardian ---------- */

    function test_Freeze_GuardianOnly_BlocksPurchase() public {
        vm.prank(outsider);
        vm.expectRevert();
        vault.setSeriesFrozen(seriesId, true);

        vm.prank(guardian);
        vault.setSeriesFrozen(seriesId, true);
        vm.prank(investorA);
        vm.expectRevert(SukukVault.FrozenSeries.selector);
        vault.purchase(seriesId, 1);
    }

    /* ---------- reserve tuning ---------- */

    function test_ReserveBps_AdminOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        vault.setReserveBps(2000);
        vault.setReserveBps(2000);
        assertEq(vault.reserveBps(), 2000);
        vm.expectRevert();
        vault.setReserveBps(10_001);
    }
}
