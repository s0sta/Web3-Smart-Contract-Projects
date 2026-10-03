// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {MockStable} from "../src/MockStable.sol";
import {TreasuryVault} from "../src/TreasuryVault.sol";

contract TreasuryVaultTest is Test {
    MockStable internal stable;
    TreasuryVault internal treasury;

    address internal authority = address(this);
    address internal vendor = address(0xB);
    address internal treasurer = address(0xC);

    function setUp() public {
        stable = new MockStable();
        treasury = new TreasuryVault(stable, authority);
    }

    function _fund(uint256 amount) internal {
        stable.setMinter(address(this));
        stable.mint(address(this), amount);
        stable.approve(address(treasury), amount);
        treasury.receiveStable(amount);
    }

    function test_ReceiveStable() public {
        _fund(1_000 ether);
        assertEq(stable.balanceOf(address(treasury)), 1_000 ether);
    }

    function test_AuthorityOnly_ReceiveAndPay() public {
        vm.prank(vendor);
        vm.expectRevert(abi.encodeWithSelector(TreasuryVault.NotAuthority.selector, vendor));
        treasury.payVendor(vendor, 1 ether);
    }

    function test_PayVendor_EnforcesReserve() public {
        _fund(1_000 ether);
        // 5% reserve of 1,000 = 50 must remain
        treasury.payVendor(vendor, 950 ether);
        assertEq(stable.balanceOf(vendor), 950 ether);
        assertEq(stable.balanceOf(address(treasury)), 50 ether);

        vm.expectRevert();
        treasury.payVendor(vendor, 49 ether); // 50 − 49 = 1 < 2 (floored 5% of 50) reserve
    }

    function test_BoardPayment_Ceiling() public {
        _fund(10_000 ether);
        treasury.grantRole(treasury.TREASURER_ROLE(), treasurer);

        vm.prank(treasurer);
        treasury.boardPayVendor(vendor, 9_000 ether);

        vm.prank(treasurer);
        vm.expectRevert();
        treasury.boardPayVendor(vendor, 1_001 ether); // 10,001 > ceiling 10,000
    }

    function test_BoardPayment_CeilingResetsAfterWindow() public {
        _fund(100_000 ether);
        treasury.setBoardPaymentCeiling(10_000 ether);
        treasury.grantRole(treasury.TREASURER_ROLE(), treasurer);

        vm.prank(treasurer);
        treasury.boardPayVendor(vendor, 10_000 ether);

        vm.warp(block.timestamp + 31 days);
        vm.prank(treasurer);
        treasury.boardPayVendor(vendor, 10_000 ether); // fresh window
    }

    function test_MaintenanceFund_Allocation() public {
        _fund(10_000 ether);
        treasury.allocateMaintenance(2_000 ether);
        assertEq(treasury.maintenanceFund(), 2_000 ether);
    }

    function test_EmergencyDrain_GuardianOnly() public {
        _fund(1_000 ether);
        treasury.grantRole(treasury.GUARDIAN_ROLE(), address(0xD));

        vm.expectRevert();
        treasury.emergencyDrain(vendor); // caller lacks GUARDIAN

        vm.prank(address(0xD));
        treasury.emergencyDrain(vendor);
        assertEq(stable.balanceOf(vendor), 1_000 ether);
    }

    function test_RecoverERC20_ProtectsOwnToken() public {
        vm.expectRevert(TreasuryVault.ProtectedToken.selector);
        treasury.recoverERC20(stable, vendor);
    }

    function test_GovernanceParameter_Setters() public {
        treasury.setReserveBps(1_000);
        assertEq(treasury.reserveBps(), 1_000);
        treasury.setBoardPaymentCeiling(5_000 ether);
        assertEq(treasury.boardPaymentCeiling(), 5_000 ether);

        vm.expectRevert();
        treasury.setReserveBps(10_001); // > 100%
    }
}
