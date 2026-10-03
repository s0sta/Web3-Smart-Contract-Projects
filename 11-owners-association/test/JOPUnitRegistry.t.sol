// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {MockStable} from "../src/MockStable.sol";
import {JOPUnitRegistry} from "../src/JOPUnitRegistry.sol";

contract JOPUnitRegistryTest is Test {
    MockStable internal stable;
    JOPUnitRegistry internal registry;

    address internal ownerA = address(0xA);
    address internal ownerB = address(0xB);

    function setUp() public {
        stable = new MockStable();
        registry = new JOPUnitRegistry(stable, address(this));
        registry.setTreasury(address(0x7));
    }

    function test_AddUnit_RegistersOwnerAndArea() public {
        registry.addUnit(120, ownerA);
        registry.addUnit(80, ownerB);

        (uint256 area0, address own0, , ) = registry.units(0);
        assertEq(area0, 120);
        assertEq(own0, ownerA);
        assertEq(registry.totalAreaSqm(), 200);
        assertEq(registry.ownerAreaSqm(ownerA), 120);
        assertEq(registry.ownerAreaSqm(ownerB), 80);
        assertEq(registry.unitCount(), 2);
    }

    function test_AddUnit_RevertsOnZeroAreaAndZeroOwner() public {
        vm.expectRevert(JOPUnitRegistry.ZeroArea.selector);
        registry.addUnit(0, ownerA);
        vm.expectRevert(JOPUnitRegistry.ZeroAddress.selector);
        registry.addUnit(100, address(0));
    }

    function test_OnlyAuthority_Mutates() public {
        vm.prank(ownerA);
        vm.expectRevert(abi.encodeWithSelector(JOPUnitRegistry.NotAuthority.selector, ownerA));
        registry.addUnit(50, ownerA);

        vm.prank(ownerA);
        vm.expectRevert(abi.encodeWithSelector(JOPUnitRegistry.NotAuthority.selector, ownerA));
        registry.setAnnualChargePerSqm(1 ether);
    }

    function test_RegisterSale_MovesAreaBetweenOwners() public {
        registry.addUnit(120, ownerA);
        registry.registerSale(0, ownerB);

        (, address own0, , ) = registry.units(0);
        assertEq(own0, ownerB);
        assertEq(registry.ownerAreaSqm(ownerA), 0);
        assertEq(registry.ownerAreaSqm(ownerB), 120);
    }

    function test_RegisterSale_Reverts_SameOwner() public {
        registry.addUnit(120, ownerA);
        vm.expectRevert(abi.encodeWithSelector(JOPUnitRegistry.SameOwner.selector, ownerA));
        registry.registerSale(0, ownerA);
    }

    function test_SnapshotPower_IsHistorical() public {
        registry.addUnit(120, ownerA);
        assertEq(registry.getPastOwnerArea(ownerA, block.number), 120);

        vm.roll(block.number + 1);
        assertEq(registry.getPastOwnerArea(ownerA, block.number - 1), 120);

        registry.registerSale(0, ownerB);
        assertEq(registry.ownerAreaSqm(ownerB), 120);
        assertEq(registry.getPastOwnerArea(ownerB, block.number), 120);
        assertEq(registry.getPastOwnerArea(ownerA, block.number), 0);
        assertEq(registry.getPastOwnerArea(ownerA, block.number - 1), 120);
    }

    function test_ServiceCharge_AccruesLinearly() public {
        registry.addUnit(120, ownerA);
        registry.setAnnualChargePerSqm(60 ether); // 60/yr per sqm

        vm.warp(block.timestamp + 365 days);
        uint256 added = registry.accrue(0);
        // 60 × 120 = 7,200 per year
        assertEq(added, 60 ether * 120);
        (, , , uint256 debt) = registry.units(0);
        assertEq(debt, 60 ether * 120);
        assertEq(registry.totalArrears(), 60 ether * 120);

        // half a year more → half the annual amount
        vm.warp(block.timestamp + 182 days);
        registry.accrue(0);
        (, , , debt) = registry.units(0);
        uint256 expected = uint256(60 ether * 120) + uint256(60 ether * 120 * 182) / uint256(365);
        assertEq(debt, expected);
    }

    function test_ServiceCharge_AccruesBeforeSale() public {
        registry.addUnit(120, ownerA);
        registry.setAnnualChargePerSqm(60 ether);
        vm.warp(block.timestamp + 365 days);

        registry.registerSale(0, ownerB);
        (, , , uint256 debt) = registry.units(0);
        assertEq(debt, 60 ether * 120); // accrued debt stays with the unit
    }

    function test_PayServiceCharge_ForwardsToTreasury() public {
        registry.addUnit(120, ownerA);
        registry.setAnnualChargePerSqm(60 ether);
        vm.warp(block.timestamp + 365 days);
        registry.accrue(0);

        stable.setMinter(address(this));
        stable.mint(ownerA, 10_000 ether);
        vm.prank(ownerA);
        stable.approve(address(registry), 10_000 ether);

        vm.prank(ownerA);
        registry.payServiceCharge(0, 7_200 ether);

        (, , , uint256 debt) = registry.units(0);
        assertEq(debt, 0);
        assertEq(registry.totalArrears(), 0);
        assertEq(stable.balanceOf(address(0x7)), 7_200 ether);
    }

    function test_PayServiceCharge_RevertsOnOverpay() public {
        registry.addUnit(120, ownerA);
        vm.prank(ownerA);
        vm.expectRevert(abi.encodeWithSelector(JOPUnitRegistry.Overpay.selector, 0, 1 ether));
        registry.payServiceCharge(0, 1 ether);
    }
}
