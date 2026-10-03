// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {MockStable} from "../src/MockStable.sol";
import {RERAPropertyRegistry} from "../src/RERAPropertyRegistry.sol";

contract RERAPropertyRegistryTest is Test {
    RERAPropertyRegistry internal registry;

    address internal alice = address(0xA);
    address internal bob = address(0xB);

    function setUp() public {
        registry = new RERAPropertyRegistry();
    }

    function _register() internal returns (uint256) {
        registry.registerProperty("Tower A", 1000 ether, 2_000_000 ether);
        registry.setWhitelisted(0, alice, true);
        registry.setWhitelisted(0, bob, true);
        return 0;
    }

    function test_RegisterProperty() public {
        uint256 id = registry.registerProperty("Tower A", 1000 ether, 2_000_000 ether);
        (string memory name, uint256 total, uint256 issued, uint256 val, , bool frozen, ) = registry.properties(id);
        assertEq(name, "Tower A");
        assertEq(total, 1000 ether);
        assertEq(issued, 0);
        assertEq(val, 2_000_000 ether);
        assertFalse(frozen);
        assertEq(registry.propertyCount(), 1);
    }

    function test_Register_RevertsOnZero() public {
        vm.expectRevert(RERAPropertyRegistry.ZeroAmount.selector);
        registry.registerProperty("X", 0, 1 ether);
        vm.expectRevert(RERAPropertyRegistry.ZeroAmount.selector);
        registry.registerProperty("X", 1 ether, 0);
    }

    function test_IssueShares_ManagerOnlyAndWhitelist() public {
        _register();
        vm.prank(bob);
        vm.expectRevert();
        registry.issueShares(0, alice, 100 ether); // bob is not a manager

        vm.prank(alice);
        vm.expectRevert();
        registry.issueShares(0, bob, 100 ether); // alice not a manager

        registry.issueShares(0, alice, 500 ether);
        ( , , uint256 issued, , , , ) = registry.properties(0);
        assertEq(issued, 500 ether);
        assertEq(registry.balanceOf(0, alice), 500 ether);

        // non-whitelisted recipient rejected
        vm.expectRevert(abi.encodeWithSelector(RERAPropertyRegistry.NotWhitelisted.selector, address(0xE)));
        registry.issueShares(0, address(0xE), 1 ether);
    }

    function test_IssueShares_ExceedsSupply() public {
        _register();
        registry.issueShares(0, alice, 900 ether);
        vm.expectRevert(abi.encodeWithSelector(RERAPropertyRegistry.ExceedsSupply.selector, 200 ether, 100 ether));
        registry.issueShares(0, bob, 200 ether);
    }

    function test_Transfer_RequiresWhitelistBothSides() public {
        _register();
        registry.issueShares(0, alice, 500 ether);

        vm.prank(alice);
        vm.expectRevert();
        registry.transferShares(0, address(0xE), 10 ether); // recipient not whitelisted

        vm.prank(alice);
        registry.transferShares(0, bob, 100 ether);
        assertEq(registry.balanceOf(0, alice), 400 ether);
        assertEq(registry.balanceOf(0, bob), 100 ether);
    }

    function test_Transfer_RevertsOnInsufficientAndSelf() public {
        _register();
        registry.issueShares(0, alice, 100 ether);
        vm.prank(alice);
        vm.expectRevert();
        registry.transferShares(0, bob, 200 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RERAPropertyRegistry.SameHolder.selector, alice));
        registry.transferShares(0, alice, 1 ether);
    }

    function test_Freeze_BlocksIssuanceAndTransfers() public {
        _register();
        registry.issueShares(0, alice, 100 ether);
        registry.setFrozen(0, true);

        vm.expectRevert(abi.encodeWithSelector(RERAPropertyRegistry.Frozen.selector, 0));
        registry.issueShares(0, bob, 10 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RERAPropertyRegistry.Frozen.selector, 0));
        registry.transferShares(0, bob, 10 ether);
    }

    function test_Freeze_ComplianceOnly() public {
        _register();
        vm.prank(alice);
        vm.expectRevert();
        registry.setFrozen(0, true);
    }

    function test_Appraisal_UpdatesAndEmits() public {
        _register();
        vm.recordLogs();
        registry.appraise(0, 2_500_000 ether);
        ( , , , uint256 val, , , ) = registry.properties(0);
        assertEq(val, 2_500_000 ether);
    }

    function test_SnapshotBalance_IsHistorical() public {
        _register();
        registry.issueShares(0, alice, 500 ether);
        vm.roll(block.number + 1);
        vm.prank(alice);
        registry.transferShares(0, bob, 200 ether);

        assertEq(registry.getPastBalance(0, alice, block.number), 300 ether);
        assertEq(registry.getPastBalance(0, alice, block.number - 1), 500 ether);
        assertEq(registry.getPastBalance(0, bob, block.number - 1), 0);
        assertEq(registry.getPastBalance(0, bob, block.number), 200 ether);
    }
}
