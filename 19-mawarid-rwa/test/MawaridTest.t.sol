// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {MawaridFixture} from "./MawaridFixture.sol";
import {MawaridAssetRegistry} from "../src/MawaridAssetRegistry.sol";
import {MawaridCompliance} from "../src/MawaridCompliance.sol";
import {MawaridShares} from "../src/MawaridShares.sol";
import {MawaridPrimaryMarket} from "../src/MawaridPrimaryMarket.sol";
import {MawaridSecondaryMarket} from "../src/MawaridSecondaryMarket.sol";
import {MawaridRentalDistributor} from "../src/MawaridRentalDistributor.sol";

contract MawaridRegistryTest is MawaridFixture {
    function test_RegisterAsset() public {
        (string memory name, string memory cls, , uint256 total, , uint256 appraisal, , MawaridAssetRegistry.Status status) =
            registry.assets(assetId);
        assertEq(name, "Marina Gate Tower - Floor 21");
        assertEq(cls, "Residential");
        assertEq(total, 1_000 ether);
        assertEq(appraisal, 5_000_000 ether);
        assertEq(uint8(status), uint8(MawaridAssetRegistry.Status.Live));
        assertEq(registry.appraisalHistory(assetId, 0), 5_000_000 ether);
    }

    function test_RegisterAsset_ManagerOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        registry.registerAsset("X", "Residential", bytes32("d"), 100, 100);
    }

    function test_Appraise_UpdatesHistory() public {
        registry.appraise(assetId, 5_500_000 ether);
        assertEq(registry.appraisalHistory(assetId, 1), 5_500_000 ether);
    }

    function test_Status_TransitionsOnly() public {
        vm.expectRevert(abi.encodeWithSelector(MawaridAssetRegistry.InvalidStatus.selector, uint8(1), uint8(0)));
        registry.setStatus(assetId, MawaridAssetRegistry.Status.Draft); // Live → Draft invalid

        registry.setStatus(assetId, MawaridAssetRegistry.Status.Frozen);
        registry.setStatus(assetId, MawaridAssetRegistry.Status.Live);
        registry.setStatus(assetId, MawaridAssetRegistry.Status.Liquidated);
    }
}

contract MawaridComplianceTest is MawaridFixture {
    function test_Kyc_ComplianceOnly() public {
        vm.prank(outsider);
        vm.expectRevert(MawaridCompliance.NotCompliance.selector);
        compliance.setKyc(outsider, MawaridCompliance.KycTier.Standard);
    }

    function test_Sanctions_BlockHolding() public {
        vm.prank(officer);
        compliance.setSanctioned(investorA, true);
        assertFalse(compliance.canHold(assetId, investorA));
        vm.prank(officer);
        compliance.setSanctioned(investorA, false);
        assertTrue(compliance.canHold(assetId, investorA));
    }

    function test_ExposureLimit() public {
        vm.expectRevert(abi.encodeWithSelector(MawaridCompliance.ExceedsExposure.selector, assetId, 950 ether, 1_000 ether));
        compliance.validateReceipt(assetId, investorA, 950 ether, 100 ether);
    }
}

contract MawaridSharesTest is MawaridFixture {
    function test_Transfer_RequiresKycBothSides() public {
        _runPrimaryRound();
        vm.prank(investorA);
        vm.expectRevert();
        shares.transfer(outsider, 1 ether); // outsider not KYC'd
        assertEq(shares.balanceOf(outsider), 0);
    }

    function test_Transfer_BetweenKycHolders() public {
        _runPrimaryRound();
        vm.prank(investorA);
        shares.transfer(investorB, 50 ether);
        assertEq(shares.balanceOf(investorA), 350 ether);
        assertEq(shares.balanceOf(investorB), 350 ether);
    }

    function test_Transfer_ExposureCapBlocks() public {
        _runPrimaryRound();
        // tighten the cap for this test: B (300) + 350 would exceed 600
        vm.prank(officer);
        compliance.setExposureLimit(assetId, 600 ether);
        vm.prank(investorA);
        vm.expectRevert();
        shares.transfer(investorB, 350 ether);
    }

    function test_ApproveAndTransferFrom() public {
        _runPrimaryRound();
        vm.prank(investorA);
        shares.approve(investorB, 100 ether);
        vm.prank(investorB);
        shares.transferFrom(investorA, investorB, 60 ether);
        assertEq(shares.balanceOf(investorA), 340 ether);
        assertEq(shares.balanceOf(investorB), 360 ether);
    }

    function test_Mint_IssuerOnly() public {
        vm.prank(outsider);
        vm.expectRevert(MawaridShares.NotIssuer.selector);
        shares.mint(outsider, 1 ether);
    }

    function test_Snapshots() public {
        _runPrimaryRound();
        vm.roll(block.number + 1);
        vm.prank(investorA);
        shares.transfer(investorB, 10 ether);
        assertEq(shares.getPastBalance(investorA, block.number), 390 ether);
        assertEq(shares.getPastBalance(investorA, block.number - 1), 400 ether);
    }

    function test_Transfers_CanBeDisabled() public {
        _runPrimaryRound();
        shares.setTransfersEnabled(false);
        vm.prank(investorA);
        vm.expectRevert(MawaridShares.TransfersDisabled.selector);
        shares.transfer(investorB, 1 ether);
    }
}

contract MawaridPrimaryMarketTest is MawaridFixture {
    function test_Subscribe_EscrowsPayment() public {
        _subscribe(investorA, 400 ether);
        assertEq(primary.subscriptions(phaseId, investorA), 400 ether);
        assertEq(stable.balanceOf(address(primary)), 40_000 ether);
        ( , , , , , uint256 subscribed, uint256 collected, , ) = primary.phases(phaseId);
        assertEq(subscribed, 400 ether);
        assertEq(collected, 40_000 ether);
    }

    function test_Subscribe_RequiresKyc() public {
        vm.prank(outsider);
        vm.expectRevert();
        primary.subscribe(phaseId, 1 ether);
    }

    function test_Subscribe_OutsideWindowReverts() public {
        vm.warp(block.timestamp + 8 days);
        vm.prank(investorA);
        vm.expectRevert(abi.encodeWithSelector(MawaridPrimaryMarket.PhaseClosed.selector, phaseId));
        primary.subscribe(phaseId, 1 ether);
    }

    function test_Subscribe_CapEnforced() public {
        _subscribe(investorA, 800 ether);
        vm.prank(investorB);
        vm.expectRevert(abi.encodeWithSelector(MawaridPrimaryMarket.CapExceeded.selector, 300 ether, 200 ether));
        primary.subscribe(phaseId, 300 ether);
    }

    function test_ClaimAllocation_MintsShares() public {
        _runPrimaryRound();
        assertEq(shares.balanceOf(investorA), 400 ether);
        assertEq(shares.balanceOf(investorB), 300 ether);
        assertEq(shares.totalSupply(), 700 ether);
        ( , , , , uint256 issued, , , ) = registry.assets(assetId);
        assertEq(issued, 700 ether);
    }

    function test_ClaimAllocation_CapBlocksOversubscription() public {
        _subscribe(investorA, 600 ether);
        vm.prank(investorB);
        vm.expectRevert(abi.encodeWithSelector(MawaridPrimaryMarket.CapExceeded.selector, 600 ether, 400 ether));
        primary.subscribe(phaseId, 600 ether); // total would exceed the 1,000 cap

        _subscribe(investorB, 400 ether); // exactly at the cap
        vm.warp(block.timestamp + 8 days);
        primary.finalizePhase(phaseId);
        vm.prank(investorA);
        primary.claimAllocation(phaseId);
        assertEq(shares.balanceOf(investorA), 600 ether);
        assertEq(stable.balanceOf(investorA), 1_000_000 ether - 60_000 ether);
    }

    function test_CancelPhase_RefundsAll() public {
        _subscribe(investorA, 100 ether);
        address[] memory subs = new address[](1);
        subs[0] = investorA;
        primary.cancelPhase(phaseId, subs);
        assertEq(stable.balanceOf(investorA), 1_000_000 ether);
    }

    function test_CancelPhase_ManagerOnly() public {
        address[] memory subs = new address[](0);
        vm.prank(outsider);
        vm.expectRevert();
        primary.cancelPhase(phaseId, subs);
    }
}

contract MawaridSecondaryMarketTest is MawaridFixture {
    function _order(uint256 amount, uint256 price) internal returns (uint256) {
        vm.prank(investorA);
        return secondary.placeOrder(assetId, amount, price);
    }

    function test_PlaceOrder_EscrowsShares() public {
        _runPrimaryRound();
        uint256 orderId = _order(100 ether, 110 ether);
        assertEq(shares.balanceOf(address(secondary)), 100 ether);
        assertEq(shares.balanceOf(investorA), 300 ether);
        ( , address seller, uint256 amount, uint256 remaining, uint256 price, bool active) = secondary.orders(orderId);
        assertEq(seller, investorA);
        assertEq(amount, 100 ether);
        assertEq(remaining, 100 ether);
        assertEq(price, 110 ether);
        assertTrue(active);
    }

    function test_FillOrder_PaysSellerNetOfFee() public {
        _runPrimaryRound();
        uint256 orderId = _order(100 ether, 110 ether);
        uint256 sellerBefore = stable.balanceOf(investorA);
        vm.prank(investorB);
        secondary.fillOrder(orderId, 100 ether);
        // buyer pays 11,000; 1% fee = 110 → seller nets 10,890
        assertEq(stable.balanceOf(investorA) - sellerBefore, 10_890 ether);
        assertEq(stable.balanceOf(address(treasury)), 110 ether);
        assertEq(shares.balanceOf(investorB), 400 ether);
        assertEq(secondary.totalFees(), 110 ether);
    }

    function test_FillOrder_RequiresKyc() public {
        _runPrimaryRound();
        uint256 orderId = _order(10 ether, 110 ether);
        vm.prank(outsider);
        vm.expectRevert();
        secondary.fillOrder(orderId, 10 ether);
    }

    function test_FillOrder_NoSelfTrade() public {
        _runPrimaryRound();
        uint256 orderId = _order(10 ether, 110 ether);
        vm.prank(investorA);
        vm.expectRevert(abi.encodeWithSelector(MawaridSecondaryMarket.SelfFill.selector, investorA));
        secondary.fillOrder(orderId, 10 ether);
    }

    function test_CancelOrder_ReturnsShares() public {
        _runPrimaryRound();
        uint256 orderId = _order(100 ether, 110 ether);
        vm.prank(investorA);
        secondary.cancelOrder(orderId);
        assertEq(shares.balanceOf(investorA), 400 ether);
        ( , , , uint256 remaining, , bool active) = secondary.orders(orderId);
        assertEq(remaining, 0);
        assertFalse(active);
    }

    function test_CancelOrder_SellerOnly() public {
        _runPrimaryRound();
        uint256 orderId = _order(10 ether, 110 ether);
        vm.prank(investorB);
        vm.expectRevert(abi.encodeWithSelector(MawaridSecondaryMarket.NotSeller.selector, orderId));
        secondary.cancelOrder(orderId);
    }

    function test_FeeBps_OperatorOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        secondary.setFeeBps(200);
        secondary.setFeeBps(200);
        assertEq(secondary.feeBps(), 200);
    }
}

contract MawaridDistributorTest is MawaridFixture {
    function _recordIncome(uint256 amount) internal {
        stable.mint(manager, amount);
        stable.approve(address(distributor), amount);
        distributor.recordIncome(assetId, amount);
    }

    function test_RecordIncome_SplitsReserve() public {
        _recordIncome(10_000 ether);
        assertEq(distributor.maintenanceFund(assetId), 1_000 ether);
        assertEq(distributor.distributablePool(assetId), 9_000 ether);
    }

    function test_DistributeAndClaim_ProRata() public {
        _runPrimaryRound();
        _recordIncome(10_000 ether);
        distributor.distribute(assetId);

        // 9,000 pool / 1,000 total shares = 9 per share
        assertEq(distributor.claimable(assetId, investorA), 400 * 9 ether);
        uint256 before = stable.balanceOf(investorA);
        vm.prank(investorA);
        distributor.claim(assetId);
        assertEq(stable.balanceOf(investorA) - before, 400 * 9 ether);
    }

    function test_Claim_SnapshotProtectsSellers() public {
        _runPrimaryRound();
        _recordIncome(10_000 ether);
        distributor.distribute(assetId); // epoch 0
        vm.roll(block.number + 1);
        vm.prank(investorA);
        shares.transfer(investorB, 100 ether); // sell after the epoch (B caps at 400)
        // the epoch's income still belongs to investorA (snapshot)
        assertEq(distributor.claimable(assetId, investorA), 400 * 9 ether);
        assertEq(distributor.claimable(assetId, investorB), 300 * 9 ether);
    }

    function test_Claim_NothingToClaim() public {
        _runPrimaryRound();
        vm.prank(investorA);
        vm.expectRevert(MawaridRentalDistributor.NothingToClaim.selector);
        distributor.claim(assetId);
    }

    function test_SpendMaintenance_ManagerOnly() public {
        _recordIncome(10_000 ether);
        vm.prank(outsider);
        vm.expectRevert();
        distributor.spendMaintenance(assetId, outsider, 100 ether);

        distributor.spendMaintenance(assetId, investorC, 500 ether);
        assertEq(stable.balanceOf(investorC), 1_000_500 ether);
    }

    function test_SpendMaintenance_InsufficientReverts() public {
        _recordIncome(10_000 ether);
        vm.expectRevert(abi.encodeWithSelector(MawaridRentalDistributor.InsufficientMaintenance.selector, 1_000 ether, 2_000 ether));
        distributor.spendMaintenance(assetId, investorC, 2_000 ether);
    }

    function test_ReserveBps_AdminOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        distributor.setMaintenanceReserveBps(2000);
        distributor.setMaintenanceReserveBps(2000);
        assertEq(distributor.maintenanceReserveBps(), 2000);
    }
}
