// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {MockStable} from "../src/MockStable.sol";
import {RERAPropertyRegistry} from "../src/RERAPropertyRegistry.sol";
import {RentalDistributor} from "../src/RentalDistributor.sol";

/// @notice Shared fixture: one registered tower, three whitelisted investors,
///         the distributor wired with a 10% maintenance reserve.
abstract contract EstateFixture is Test {
    MockStable internal stable;
    RERAPropertyRegistry internal registry;
    RentalDistributor internal distributor;

    address internal manager = address(this);
    address internal compliance = address(0xC);
    address internal alice = address(0xA);
    address internal bob = address(0xB);
    address internal carol = address(0xD);
    address internal outsider = address(0x9);

    uint256 internal propertyId;

    function setUp() public virtual {
        stable = new MockStable();
        registry = new RERAPropertyRegistry();
        distributor = new RentalDistributor(registry, stable, 1000); // 10% reserve

        registry.grantRole(registry.COMPLIANCE_ROLE(), compliance);
        distributor.grantRole(distributor.COMPLIANCE_ROLE(), compliance);

        propertyId = registry.registerProperty("Marina Gate Tower - Floor 21", 1000 ether, 5_000_000 ether);

        for (uint256 i = 1; i < 6; i++) {
            registry.setWhitelisted(propertyId, address(uint160(i)), true);
        }
        registry.setWhitelisted(propertyId, alice, true);
        registry.setWhitelisted(propertyId, bob, true);
        registry.setWhitelisted(propertyId, carol, true);

        registry.issueShares(propertyId, alice, 400 ether);
        registry.issueShares(propertyId, bob, 300 ether);
        registry.issueShares(propertyId, carol, 300 ether);

        // seed the distributor with rent tokens
        stable.setMinter(address(this));
        stable.mint(address(this), 1_000_000 ether);
        stable.approve(address(distributor), 1_000_000 ether);
    }

    function _payRent(uint256 amount) internal {
        distributor.payRent(propertyId, amount);
    }
}
