// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {EstateFixture} from "./EstateFixture.sol";
import {RentalDistributor} from "../src/RentalDistributor.sol";

contract RentalDistributorTest is EstateFixture {
    function test_PayRent_SplitsReserve() public {
        _payRent(10_000 ether);
        assertEq(distributor.maintenanceFund(propertyId), 1_000 ether); // 10%
        assertEq(distributor.pendingPool(propertyId), 9_000 ether);
        assertEq(distributor.totalRentReceived(propertyId), 10_000 ether);
    }

    function test_Distribute_RecordsEpoch() public {
        _payRent(10_000 ether);
        uint256 epochId = distributor.distribute(propertyId);
        assertEq(epochId, 0);
        (uint32 snap, uint256 pool, uint256 perShare) = distributor.epochs(propertyId, 0);
        assertEq(pool, 9_000 ether);
        assertEq(perShare, 9 ether); // 9,000 / 1,000 shares
        assertEq(snap, uint32(block.number));
        assertEq(distributor.pendingPool(propertyId), 0);
    }

    function test_Claim_ProRataAcrossEpochs() public {
        _payRent(10_000 ether); // pool 9,000 → 9/share
        distributor.distribute(propertyId);
        _payRent(20_000 ether); // pool 18,000 → 18/share
        distributor.distribute(propertyId);

        // alice holds 400 shares → 400 × (9 + 18) = 10,800
        assertEq(distributor.claimable(propertyId, alice), 400 * 27 ether);
        uint256 balBefore = stable.balanceOf(alice);
        vm.prank(alice);
        distributor.claim(propertyId);
        assertEq(stable.balanceOf(alice) - balBefore, 400 * 27 ether);

        // second claim: nothing new
        vm.prank(alice);
        vm.expectRevert(RentalDistributor.NothingToClaim.selector);
        distributor.claim(propertyId);
    }

    function test_Claim_SnapshotPreventsPostEpochTransfers() public {
        _payRent(10_000 ether);
        distributor.distribute(propertyId); // epoch 0 snapshot

        vm.roll(block.number + 1); // the sale settles in a later block than the epoch
        vm.prank(alice);
        registry.transferShares(propertyId, bob, 400 ether); // alice sells AFTER the epoch

        // epoch income still belongs to alice (snapshot), not bob
        assertEq(distributor.claimable(propertyId, alice), 400 * 9 ether);
        assertEq(distributor.claimable(propertyId, bob), 300 * 9 ether);
    }

    function test_Claim_RevertsWhenNothing() public {
        vm.prank(alice);
        vm.expectRevert(RentalDistributor.NothingToClaim.selector);
        distributor.claim(propertyId);
    }

    function test_SpendMaintenance_ManagerOnly() public {
        _payRent(10_000 ether);
        address vendor = address(0xE);

        vm.prank(alice);
        vm.expectRevert();
        distributor.spendMaintenance(propertyId, vendor, 100 ether);

        distributor.spendMaintenance(propertyId, vendor, 500 ether);
        assertEq(distributor.maintenanceFund(propertyId), 500 ether);
        assertEq(stable.balanceOf(vendor), 500 ether);

        vm.expectRevert(abi.encodeWithSelector(RentalDistributor.InsufficientMaintenance.selector, 500 ether, 600 ether));
        distributor.spendMaintenance(propertyId, vendor, 600 ether);
    }

    function test_ReserveBps_ManagerOnly() public {
        vm.prank(alice);
        vm.expectRevert();
        distributor.setMaintenanceReserveBps(2000);

        distributor.setMaintenanceReserveBps(2000);
        assertEq(distributor.maintenanceReserveBps(), 2000);

        vm.expectRevert();
        distributor.setMaintenanceReserveBps(10_001);
    }

    function test_Pause_ComplianceOnly_AndBlocksRent() public {
        vm.prank(alice);
        vm.expectRevert();
        distributor.setPaused(propertyId, true);

        vm.prank(compliance);
        distributor.setPaused(propertyId, true);
        vm.expectRevert(abi.encodeWithSelector(RentalDistributor.PropertyPaused.selector, propertyId));
        _payRent(1 ether);

        vm.prank(compliance);
        distributor.setPaused(propertyId, false);
        _payRent(1 ether);
    }

    function test_PayRent_UnknownPropertyReverts() public {
        vm.expectRevert(abi.encodeWithSelector(RentalDistributor.UnknownProperty.selector, 99));
        distributor.payRent(99, 1 ether);
    }

    function test_Distribute_ZeroPoolReverts() public {
        vm.expectRevert(RentalDistributor.ZeroAmount.selector);
        distributor.distribute(propertyId);
    }
}
