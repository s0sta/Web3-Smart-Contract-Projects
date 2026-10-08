// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {TaqaFixture} from "./TaqaFixture.sol";
import {TaqaRegistry} from "../src/TaqaRegistry.sol";
import {TaqaOracle} from "../src/TaqaOracle.sol";
import {TaqaMeters} from "../src/TaqaMeters.sol";
import {TaqaCertificates} from "../src/TaqaCertificates.sol";
import {TaqaCarbon} from "../src/TaqaCarbon.sol";
import {TaqaTreasury} from "../src/TaqaTreasury.sol";
import {TaqaMarket} from "../src/TaqaMarket.sol";
import {TaqaP2P} from "../src/TaqaP2P.sol";
import {TaqaRetirement} from "../src/TaqaRetirement.sol";
import {TaqaCompliance} from "../src/TaqaCompliance.sol";
import {TaqaGovernor} from "../src/TaqaGovernor.sol";

contract TaqaRegistryTest is TaqaFixture {
    function test_Register() public {
        assertEq(uint8(registry.roleOf(producer)), uint8(TaqaRegistry.Role.Producer));
        assertEq(registry.participantCount(), 3);
    }

    function test_Freeze_OfficerOnly() public {
        vm.prank(outsider);
        vm.expectRevert(TaqaRegistry.NotOfficer.selector);
        registry.setFrozen(producer, true);
        vm.prank(officer);
        registry.setFrozen(producer, true);
        assertFalse(registry.isActive(producer));
    }
}

contract TaqaOracleTest is TaqaFixture {
    function test_EnergyPrice() public {
        assertEq(oracle.price(address(aeds)), 500_000_000_000_000_000);
    }

    function test_ProductionTelemetry() public {
        oracle.postProduction(bytes32("meter-001"), 2_000);
        assertEq(oracle.production(bytes32("meter-001")), 2_000);
    }

    function test_Pause_Guardian() public {
        vm.prank(outsider);
        vm.expectRevert();
        oracle.pause();
        vm.prank(guardian);
        oracle.pause();
        vm.expectRevert(TaqaOracle.FeedPaused.selector);
        oracle.price(address(aeds));
    }
}

contract TaqaMetersTest is TaqaFixture {
    function test_Register_ProducerOnly() public {
        vm.prank(consumer);
        vm.expectRevert(abi.encodeWithSelector(TaqaMeters.NotOwnerOrAuditor.selector, 0));
        meters.registerMeter(bytes32("x"), 1_000);
    }

    function test_Attest_Issuable() public {
        ( , , , uint256 attested, , ) = meters.meters(meterId);
        assertEq(attested, 5_000);
        assertEq(attested / meters.KWH_PER_CERT(), 5);
    }

    function test_RecordProduction_AuditorGated() public {
        vm.prank(outsider);
        vm.expectRevert();
        meters.recordProduction(meterId, bytes32("meter-001"), 100);
        vm.prank(auditor);
        meters.recordProduction(meterId, bytes32("meter-001"), 100);
        ( , , uint256 produced, , , ) = meters.meters(meterId);
        assertEq(produced, 100);
    }

    function test_Deactivate() public {
        vm.prank(producer);
        meters.deactivate(meterId);
        ( , , , , , bool active) = meters.meters(meterId);
        assertFalse(active);
    }
}

contract TaqaCertificatesTest is TaqaFixture {
    function test_Mint_AuditorOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        certificates.mint(meterId, 5);
    }

    function test_Mint_AndTransfer() public {
        vm.prank(auditor);
        certificates.mint(meterId, 5);
        assertEq(certificates.balanceOf(producer), 5);
        assertEq(certificates.totalSupply(), 5);
        vm.prank(producer);
        certificates.transfer(consumer, 2);
        assertEq(certificates.balanceOf(consumer), 2);
    }

    function test_Transfer_Insufficient() public {
        vm.prank(auditor);
        certificates.mint(meterId, 5);
        vm.prank(producer);
        vm.expectRevert(abi.encodeWithSelector(TaqaCertificates.InsufficientBalance.selector, 5, 6));
        certificates.transfer(consumer, 6);
    }
}

contract TaqaCarbonTest is TaqaFixture {
    function test_Mint_AuditorOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        carbon.mint(producer, 100, 2026);
    }

    function test_Mint_WithVintage() public {
        vm.prank(auditor);
        uint256 id = carbon.mint(producer, 100, 2026);
        (address project, uint256 amount, uint64 vintage, ) = carbon.vers(id);
        assertEq(project, producer);
        assertEq(amount, 100);
        assertEq(vintage, 2026);
    }

    function test_Transfer() public {
        vm.prank(auditor);
        carbon.mint(producer, 100, 2026);
        vm.prank(producer);
        carbon.transfer(consumer, 40);
        assertEq(carbon.balanceOf(consumer), 40);
    }
}

contract TaqaMarketTest is TaqaFixture {
    function _mintAndList() internal returns (uint256) {
        vm.prank(auditor);
        certificates.mint(meterId, 5);
        vm.prank(producer);
        return market.placeOrder(TaqaMarket.AssetKind.Rec, 40 ether, 3);
    }

    function test_PlaceOrder_Escrows() public {
        uint256 id = _mintAndList();
        (address seller, , uint256 price, uint256 amount, bool active) = market.orders(id);
        assertEq(seller, producer);
        assertEq(price, 40 ether);
        assertEq(amount, 3);
        assertTrue(active);
        assertEq(certificates.balanceOf(address(market)), 3);
    }

    function test_Fill_PaysSeller() public {
        uint256 id = _mintAndList();
        uint256 before = aeds.balanceOf(producer);
        vm.prank(consumer);
        market.fill(id, 2);
        // 2 × 40 = 80 − 0.5% fee = 79.6
        assertEq(aeds.balanceOf(producer) - before, 79_600_000_000_000_000_000); // 2 × 40 − 0.5%
        assertEq(certificates.balanceOf(consumer), 2);
    }

    function test_SelfFill_Reverts() public {
        uint256 id = _mintAndList();
        vm.prank(producer);
        vm.expectRevert(abi.encodeWithSelector(TaqaMarket.SelfFill.selector, producer));
        market.fill(id, 1);
    }

    function test_Cancel_Refunds() public {
        uint256 id = _mintAndList();
        vm.prank(producer);
        market.cancelOrder(id);
        assertEq(certificates.balanceOf(producer), 5);
    }

    function test_CarbonOrders() public {
        vm.prank(auditor);
        carbon.mint(producer, 100, 2026);
        vm.prank(producer);
        uint256 id = market.placeOrder(TaqaMarket.AssetKind.Carbon, 10 ether, 50);
        uint256 before = aeds.balanceOf(producer);
        vm.prank(consumer);
        market.fill(id, 10);
        assertEq(carbon.balanceOf(consumer), 10);
        assertEq(aeds.balanceOf(producer) - before, 99_500_000_000_000_000_000); // 10 × 10 − 0.5%
    }
}

contract TaqaP2PTest is TaqaFixture {
    function test_PostOffer_ProducerOnly() public {
        vm.prank(consumer);
        vm.expectRevert(abi.encodeWithSelector(TaqaP2P.NotProducer.selector, 0));
        p2p.postOffer(1_000, 1);
    }

    function test_Buy() public {
        vm.prank(producer);
        uint256 id = p2p.postOffer(1_000 ether, 500_000_000_000_000_000); // 0.5 per kWh
        uint256 before = aeds.balanceOf(producer);
        vm.prank(consumer);
        p2p.buy(id, 100 ether);
        // 100 × 0.5 = 50 − 0.3% = 49.85
        assertEq(aeds.balanceOf(producer) - before, 49_850_000_000_000_000_000);
        assertEq(p2p.consumedKwh(consumer), 100 ether);
    }

    function test_Buy_OverKwh() public {
        vm.prank(producer);
        uint256 id = p2p.postOffer(100 ether, 500_000_000_000_000_000);
        vm.prank(consumer);
        vm.expectRevert(abi.encodeWithSelector(TaqaP2P.InsufficientKwh.selector, 100 ether, 200 ether));
        p2p.buy(id, 200 ether);
    }
}

contract TaqaRetirementTest is TaqaFixture {
    function test_RetireRec() public {
        vm.prank(auditor);
        certificates.mint(meterId, 5);
        vm.prank(producer);
        uint256 id = retirement.retireRec(2, "2026 ESG report");
        assertEq(retirement.retiredRec(producer), 2);
        assertEq(certificates.balanceOf(producer), 3);
        (address retirer, bool isRec, uint256 amount, string memory claim, ) = retirement.retirements(id);
        assertEq(retirer, producer);
        assertTrue(isRec);
        assertEq(amount, 2);
    }

    function test_RetireCarbon() public {
        vm.prank(auditor);
        carbon.mint(producer, 100, 2026);
        vm.prank(producer);
        retirement.retireCarbon(30, "net-zero claim");
        assertEq(retirement.retiredCarbon(producer), 30);
        assertEq(carbon.balanceOf(producer), 70);
    }

    function test_DoubleRetire_Blocked() public {
        vm.prank(auditor);
        certificates.mint(meterId, 5);
        vm.prank(producer);
        retirement.retireRec(5, "claim");
        vm.prank(producer);
        vm.expectRevert(abi.encodeWithSelector(TaqaRetirement.InsufficientBalance.selector, 0, 1));
        retirement.retireRec(1, "double");
    }
}

contract TaqaGovernorTest is TaqaFixture {
    function test_Propose_CertWeighted() public {
        vm.prank(auditor);
        certificates.mint(meterId, 5);
        vm.prank(producer);
        uint256 id = governor.propose(address(p2p), 0, abi.encodeCall(p2p.setFee, (50)), "raise P2P fee");
        vm.warp(block.timestamp + 3 days);
        vm.prank(producer);
        governor.vote(id, true);
        ( , , , , , uint256 forV, , , , , , , ) = governor.proposals(id);
        assertEq(forV, 5); // holds 5 RECs
    }

    function test_FullLifecycle_ChangesFee() public {
        vm.prank(auditor);
        certificates.mint(meterId, 5);
        vm.prank(producer);
        uint256 id = governor.propose(address(p2p), 0, abi.encodeCall(p2p.setFee, (50)), "raise fee");
        vm.warp(block.timestamp + 3 days);
        vm.prank(producer);
        governor.vote(id, true);
        vm.warp(block.timestamp + 10 days);
        assertEq(governor.state(id), 3);
        governor.execute(id);
        assertEq(governor.state(id), 4);
        assertEq(p2p.feeBps(), 50);
    }

    function test_InvalidTarget_Rejected() public {
        vm.expectRevert(TaqaGovernor.InvalidTargets.selector);
        governor.propose(address(0xDEAD), 0, hex"1234", "escape");
    }

    function test_Timelock_BlocksEarly() public {
        vm.prank(auditor);
        certificates.mint(meterId, 5);
        vm.prank(producer);
        uint256 id = governor.propose(address(p2p), 0, abi.encodeCall(p2p.setFee, (50)), "timelocked");
        vm.warp(block.timestamp + 3 days);
        vm.prank(producer);
        governor.vote(id, true);
        vm.warp(block.timestamp + 5 days);
        vm.expectRevert();
        governor.execute(id);
        assertEq(governor.state(id), 2);
    }

    function test_Pause_GuardianOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        governor.pause();
        vm.prank(guardian);
        governor.pause();
        vm.expectRevert(TaqaGovernor.ProtocolPaused.selector);
        governor.propose(address(p2p), 0, hex"1234", "paused");
    }
}
