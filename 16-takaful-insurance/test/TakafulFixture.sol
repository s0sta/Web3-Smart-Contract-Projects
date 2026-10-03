// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {MockStable} from "../src/MockStable.sol";
import {TakafulPool} from "../src/TakafulPool.sol";

/// @notice Shared fixture: "Amanah Mutual" takaful with a motor pool
///         (500 AED-S contribution, 10% wakalah, 2,000 claim limit,
///         90-day coverage, 30-day accounting periods) and 3 assessors.
abstract contract TakafulFixture is Test {
    MockStable internal stable;
    TakafulPool internal pool;

    address internal operator = address(this);
    address internal assessor1 = address(0xC);
    address internal assessor2 = address(0xD);
    address internal assessor3 = address(0xE);
    address internal guardian = address(0x6);
    address internal alice = address(0xA);
    address internal bob = address(0xB);
    address internal outsider = address(0x99);

    uint256 internal motorPoolId;

    function setUp() public virtual {
        stable = new MockStable();
        pool = new TakafulPool(stable);
        pool.grantRole(pool.ASSESSOR_ROLE(), assessor1);
        pool.grantRole(pool.ASSESSOR_ROLE(), assessor2);
        pool.grantRole(pool.ASSESSOR_ROLE(), assessor3);
        pool.grantRole(pool.GUARDIAN_ROLE(), guardian);
        pool.setAssessorCount(3);

        motorPoolId = pool.registerPool("Motor", 500 ether, 1000, 2_000 ether, 90 days, 30 days);

        stable.setMinter(address(this));
        for (uint256 i = 1; i < 9; i++) {
            stable.mint(address(uint160(i)), 100_000 ether);
            vm.prank(address(uint160(i)));
            stable.approve(address(pool), 100_000 ether);
        }
        stable.mint(alice, 100_000 ether);
        stable.mint(bob, 100_000 ether);
        vm.prank(alice);
        stable.approve(address(pool), 100_000 ether);
        vm.prank(bob);
        stable.approve(address(pool), 100_000 ether);
    }

    function _join(address who) internal returns (uint256 policyId) {
        vm.prank(who);
        return pool.joinPool(motorPoolId);
    }

    function _approveClaim(uint256 claimId) internal {
        vm.prank(assessor1);
        pool.voteClaim(claimId, true);
        vm.prank(assessor2);
        pool.voteClaim(claimId, true);
    }
}
