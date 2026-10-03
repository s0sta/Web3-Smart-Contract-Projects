// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {MockStable} from "../src/MockStable.sol";
import {AsnafRegistry} from "../src/AsnafRegistry.sol";
import {ZakatEngine} from "../src/ZakatEngine.sol";

/// @notice Shared fixture: nisab 4,000 AED-S (85g gold equivalent), committee of
///         three, allocations 40/40/10/10 across the first four asnaf, two
///         registered recipients, one wealthy payer.
abstract contract ZakatFixture is Test {
    MockStable internal stable;
    AsnafRegistry internal registry;
    ZakatEngine internal engine;

    address internal committee1 = address(0xC);
    address internal committee2 = address(0xD);
    address internal guardian = address(0x6);
    address internal payer = address(0xA);
    address internal recipient1 = address(0x1);
    address internal recipient2 = address(0x2);
    address internal outsider = address(0x99);

    uint256 internal recipientId1;
    uint256 internal recipientId2;

    function setUp() public virtual {
        stable = new MockStable();
        address[] memory members = new address[](2);
        members[0] = committee1;
        members[1] = committee2;
        registry = new AsnafRegistry(members);
        engine = new ZakatEngine(registry, stable, 4_000 ether);

        engine.grantRole(engine.COMMITTEE_ROLE(), committee1);
        engine.grantRole(engine.COMMITTEE_ROLE(), committee2);
        engine.grantRole(engine.GUARDIAN_ROLE(), guardian);
        registry.setEngine(address(engine));

        registry.setAllocation(0, 4000);
        registry.setAllocation(1, 4000);
        registry.setAllocation(2, 1000);
        registry.setAllocation(3, 1000);

        recipientId1 = registry.registerRecipient(recipient1, 0, bytes32("proof-1"));
        recipientId2 = registry.registerRecipient(recipient2, 1, bytes32("proof-2"));

        stable.setMinter(address(this));
        stable.mint(payer, 1_000_000 ether);
        vm.prank(payer);
        stable.approve(address(engine), 1_000_000 ether);

        vm.prank(payer);
        engine.declareWealth(100_000 ether);
    }
}
