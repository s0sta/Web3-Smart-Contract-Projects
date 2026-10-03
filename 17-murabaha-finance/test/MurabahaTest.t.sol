// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {MurabahaFixture} from "./MurabahaFixture.sol";
import {MurabahaFinancing} from "../src/MurabahaFinancing.sol";

contract MurabahaTest is MurabahaFixture {
    /* ---------- request & approval ---------- */

    function test_RequestTrade() public {
        (address b, address s, address g, uint256 cost, uint256 markup, uint256 instAmt, uint256 inst, , , , , , , string memory asset, MurabahaFinancing.Status status) =
            murabaha.trades(tradeId);
        assertEq(b, buyer);
        assertEq(s, supplier);
        assertEq(g, guarantor);
        assertEq(cost, 10_000 ether);
        assertEq(markup, 1_000 ether);
        assertEq(instAmt, 1_100 ether); // 11,000 / 10
        assertEq(inst, 10);
        assertEq(asset, "Solar panels, 40 kW");
        assertEq(uint8(status), 0); // Requested
    }

    function test_Request_MarkupCap() public {
        vm.prank(buyer);
        vm.expectRevert(MurabahaFinancing.InvalidMarkup.selector);
        murabaha.requestTrade(supplier, guarantor, 10_000 ether, 6_000 ether, 10, 30 days, bytes32("x"), "overpriced");
    }

    function test_Approve_ShariahOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        murabaha.approveTrade(tradeId);

        vm.prank(shariah);
        murabaha.approveTrade(tradeId);
        ( , , , , , , , , , , , , , , MurabahaFinancing.Status status) = murabaha.trades(tradeId);
        assertEq(uint8(status), 1); // Approved
    }

    function test_Purchase_FinancierOnly_PaysSupplier() public {
        vm.prank(shariah);
        murabaha.approveTrade(tradeId);

        vm.prank(outsider);
        vm.expectRevert();
        murabaha.purchaseAsset(tradeId);

        uint256 supplierBefore = stable.balanceOf(supplier);
        murabaha.purchaseAsset(tradeId);
        assertEq(stable.balanceOf(supplier) - supplierBefore, 10_000 ether);
    }

    function test_ConfirmDelivery_BuyerOnly() public {
        vm.prank(shariah);
        murabaha.approveTrade(tradeId);
        murabaha.purchaseAsset(tradeId);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(MurabahaFinancing.NotBuyer.selector, tradeId));
        murabaha.confirmDelivery(tradeId);

        vm.prank(buyer);
        murabaha.confirmDelivery(tradeId);
    }

    /* ---------- repayment ---------- */

    function test_PayInstallment_FullLifecycle() public {
        _approveAndPurchase();
        uint256 before = stable.balanceOf(buyer);
        _payInstallments(10);
        assertEq(before - stable.balanceOf(buyer), 11_000 ether); // full cost+markup
        ( , , , , , , , uint256 paid, , , , , , , MurabahaFinancing.Status status) = murabaha.trades(tradeId);
        assertEq(paid, 10);
        assertEq(uint8(status), 5); // Settled
    }

    function test_PayInstallment_GuarantorMayPay() public {
        _approveAndPurchase();
        vm.prank(guarantor);
        murabaha.payInstallment(tradeId);
        ( , , , , , , , uint256 paid, , , , , , , ) = murabaha.trades(tradeId);
        assertEq(paid, 1);
    }

    function test_PayInstallment_BeforeDeliveryReverts() public {
        vm.prank(shariah);
        murabaha.approveTrade(tradeId);
        vm.prank(buyer);
        vm.expectRevert();
        murabaha.payInstallment(tradeId);
    }

    /* ---------- late penalty → charity ---------- */

    function test_LatePayment_PenaltyGoesToCharity() public {
        _approveAndPurchase();
        // two installments come due after 61 days (30d first due + 1 interval)
        vm.warp(block.timestamp + 61 days);
        uint256 charityBefore = stable.balanceOf(charity);
        vm.prank(buyer);
        murabaha.payInstallment(tradeId);
        // fee = installment(1,100) × 2% × 2 missed = 44 AED-S → charity
        assertEq(stable.balanceOf(charity) - charityBefore, 44 ether);
        ( , , , , , , , uint256 paid, , , uint256 fee, , , , ) = murabaha.trades(tradeId);
        assertEq(paid, 3); // caught up all three due installments
        assertEq(fee, 44 ether);
    }

    /* ---------- early settlement ---------- */

    function test_SettleEarly_WithRebate() public {
        _approveAndPurchase();
        _payInstallments(4);
        uint256 before = stable.balanceOf(buyer);
        vm.prank(buyer);
        murabaha.settleEarly(tradeId);
        // remaining 6 × 1,100 = 6,600; remaining markup = 600; rebate 5% of 600 = 30
        assertEq(before - stable.balanceOf(buyer), 6_600 ether - 30 ether);
        ( , , , , , , , , , , , uint256 rebate, , , MurabahaFinancing.Status status) = murabaha.trades(tradeId);
        assertEq(rebate, 30 ether);
        assertEq(uint8(status), 5);
    }

    function test_SettleEarly_BuyerOnly() public {
        _approveAndPurchase();
        _payInstallments(1);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(MurabahaFinancing.NotBuyer.selector, tradeId));
        murabaha.settleEarly(tradeId);
    }

    /* ---------- default & recovery ---------- */

    function test_Default_AfterMaxMissed() public {
        _approveAndPurchase();
        _payInstallments(1);
        // 4 installments come due: 121 days → due = 4 → missed = 3 > 2 max
        vm.warp(block.timestamp + 121 days);
        murabaha.markDefault(tradeId);
        ( , , , , , , , , , , , , , , MurabahaFinancing.Status status) = murabaha.trades(tradeId);
        assertEq(uint8(status), 6); // Defaulted
    }

    function test_Default_NotYetReverts() public {
        _approveAndPurchase();
        _payInstallments(1);
        vm.expectRevert(MurabahaFinancing.NoInstallmentsDue.selector);
        murabaha.markDefault(tradeId);
    }

    function test_Recover_FinancierOnly_AfterDefault() public {
        _approveAndPurchase();
        _payInstallments(1);
        vm.warp(block.timestamp + 121 days);
        murabaha.markDefault(tradeId);

        vm.prank(outsider);
        vm.expectRevert();
        murabaha.recover(tradeId, financier, 1 ether);

        uint256 before = stable.balanceOf(financier);
        murabaha.recover(tradeId, financier, 1_100 ether); // collected installment
        assertEq(stable.balanceOf(financier) - before, 1_100 ether);
    }

    /* ---------- charity & pause ---------- */

    function test_SetCharity_AdminOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        murabaha.setCharity(outsider);
        murabaha.setCharity(address(0x8));
        assertEq(murabaha.charity(), address(0x8));
    }

    function test_Pause_GuardianOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        murabaha.pause();

        vm.prank(guardian);
        murabaha.pause();
        vm.prank(buyer);
        vm.expectRevert(MurabahaFinancing.ProtocolPaused.selector);
        murabaha.requestTrade(supplier, guarantor, 1_000 ether, 100 ether, 4, 30 days, bytes32("x"), "paused");
    }
}
