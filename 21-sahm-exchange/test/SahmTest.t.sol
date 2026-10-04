// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {SahmFixture} from "./SahmFixture.sol";
import {SahmCompliance} from "../src/SahmCompliance.sol";
import {SahmOracle} from "../src/SahmOracle.sol";
import {SahmCollateral} from "../src/SahmCollateral.sol";
import {SahmTreasury} from "../src/SahmTreasury.sol";
import {SahmRisk} from "../src/SahmRisk.sol";

contract SahmComplianceTest is SahmFixture {
    function test_Kyc_OfficerOnly() public {
        vm.prank(outsider);
        vm.expectRevert(SahmCompliance.NotCompliance.selector);
        compliance.setKyc(outsider, SahmCompliance.KycTier.Retail);
    }

    function test_VolumeCap_Enforced() public {
        vm.prank(officer);
        compliance.setVolumeCap(SahmCompliance.KycTier.Professional, 100 ether);
        vm.prank(traderA);
        vm.expectRevert();
        compliance.recordVolume(traderA, 200 ether);
    }

    function test_VolumeCap_RollsDaily() public {
        vm.prank(officer);
        compliance.setVolumeCap(SahmCompliance.KycTier.Professional, 100 ether);
        vm.prank(traderA);
        compliance.recordVolume(traderA, 100 ether);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(traderA);
        compliance.recordVolume(traderA, 100 ether); // new window
    }

    function test_Halt_BlocksTrading() public {
        vm.prank(officer);
        compliance.setTradingHalted(true);
        assertFalse(compliance.canTrade(traderA));
    }
}

contract SahmOracleTest is SahmFixture {
    function test_Ema_Smooths() public {
        oracle.postPrice(address(stable), 2_000 ether);
        vm.warp(block.timestamp + 30 minutes);
        oracle.postPrice(address(stable), 3_000 ether);
        uint256 ema = oracle.price(address(stable));
        assertTrue(ema > 2_000 ether && ema < 3_000 ether);
    }

    function test_Stale_Reverts() public {
        vm.warp(block.timestamp + 25 hours);
        vm.expectRevert();
        oracle.price(address(stable));
    }

    function test_Pause_Guardian() public {
        vm.prank(outsider);
        vm.expectRevert();
        oracle.pause();
        vm.prank(guardian);
        oracle.pause();
        vm.expectRevert(SahmOracle.FeedPaused.selector);
        oracle.price(address(stable));
    }
}

contract SahmCollateralTest is SahmFixture {
    function test_DepositWithdraw() public {
        uint256 before = stable.balanceOf(traderA);
        vm.prank(traderA);
        collateral.withdraw(10_000 ether);
        assertEq(stable.balanceOf(traderA) - before, 10_000 ether);
    }

    function test_Withdraw_RespectsLocked() public {
        _openLong(traderA, 5_000 ether, 200); // locks 5,000
        vm.prank(traderA);
        vm.expectRevert();
        collateral.withdraw(96_000 ether); // 95,000 free
        vm.prank(traderA);
        collateral.withdraw(95_000 ether); // exactly the free margin
    }

    function test_Lock_OnlyVenues() public {
        vm.prank(outsider);
        vm.expectRevert();
        collateral.lockMargin(traderA, 1 ether);
    }
}

contract SahmTreasuryTest is SahmFixture {
    function test_ReceiveAndPayVendor() public {
        stable.mint(address(this), 2_000 ether);
        stable.approve(address(treasury), 1_000 ether);
        treasury.receiveFees(1_000 ether);
        assertEq(treasury.totalFeesCollected(), 1_000 ether);
        treasury.setVendor(traderB, true);
        // reserve floor = 20% of 1,000 = 200 → paying 900 breaches
        vm.expectRevert(abi.encodeWithSelector(SahmTreasury.ReserveBreach.selector, 100 ether, 200 ether));
        treasury.payVendor(traderB, 900 ether);
        treasury.payVendor(traderB, 700 ether); // leaves 300 ≥ 200
        assertEq(stable.balanceOf(traderB), 900_700 ether); // minus the 100k margin deposit
    }

    function test_Drain_GuardianOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        treasury.drain(outsider);
    }
}

contract SahmRiskTest is SahmFixture {
    function test_PositionCap() public {
        vm.expectRevert();
        risk.validatePosition(address(stable), traderA, 2_000_000 ether);
    }

    function test_CircuitBreaker_Trips() public {
        bool ok = risk.checkMove(address(stable), 2_000 ether, 2_500 ether); // 25% move > 10% band
        assertFalse(ok);
        ( , , , bool halted) = risk.risks(address(stable));
        assertTrue(halted);
    }

    function test_VolumeCap_Enforced() public {
        vm.prank(address(book));
        vm.expectRevert();
        risk.recordVolume(address(stable), 6_000_000 ether);
    }
}
