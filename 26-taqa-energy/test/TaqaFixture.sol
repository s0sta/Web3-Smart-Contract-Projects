// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {MockStable} from "../src/MockStable.sol";
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

/// @notice The complete energy market: AED-S settlement, a registry with a
///         producer, a consumer and an auditor, zone compliance (UAE allowed),
///         the EMA oracle (energy tariff 0.5 AED/kWh, carbon 40 AED/tonne),
///         the meter registry (1 REC = 1,000 kWh), certificates, carbon
///         credits, the certificate market (0.5% fee), P2P energy trading
///         (0.3% fee), the retirement desk, the treasury (20% reserve) and
///         the governor.
abstract contract TaqaFixture is Test {
    MockStable internal aeds;
    TaqaRegistry internal registry;
    TaqaOracle internal oracle;
    TaqaMeters internal meters;
    TaqaCertificates internal certificates;
    TaqaCarbon internal carbon;
    TaqaTreasury internal treasury;
    TaqaMarket internal market;
    TaqaP2P internal p2p;
    TaqaRetirement internal retirement;
    TaqaCompliance internal compliance;
    TaqaGovernor internal governor;

    address internal officer = address(0xC);
    address internal guardian = address(0x6);
    address internal producer = address(0xA);
    address internal consumer = address(0xB);
    address internal auditor = address(0xD);
    address internal outsider = address(0x99);

    uint64 internal ZONE_UAE = 784;

    uint256 internal meterId;

    function setUp() public virtual {
        aeds = new MockStable();
        registry = new TaqaRegistry();
        oracle = new TaqaOracle(1 hours, 24 hours);
        meters = new TaqaMeters(registry, oracle);
        certificates = new TaqaCertificates(registry, meters);
        carbon = new TaqaCarbon(registry);
        treasury = new TaqaTreasury(aeds, 2000);
        market = new TaqaMarket(registry, certificates, carbon, treasury, aeds);
        p2p = new TaqaP2P(registry, oracle, treasury, aeds);
        retirement = new TaqaRetirement(registry, certificates, carbon);
        compliance = new TaqaCompliance(registry);
        governor = new TaqaGovernor(registry, compliance, meters, certificates, carbon, market, p2p, retirement, treasury, oracle, 0);

        // wiring
        registry.grantRole(registry.OFFICER_ROLE(), officer);
        compliance.grantRole(compliance.OFFICER_ROLE(), officer);
        certificates.grantRole(certificates.AUDITOR_ROLE(), auditor);
        certificates.grantRole(certificates.MARKET_ROLE(), address(market));
        certificates.grantRole(certificates.RETIREMENT_ROLE(), address(retirement));
        carbon.grantRole(carbon.AUDITOR_ROLE(), auditor);
        carbon.grantRole(carbon.MARKET_ROLE(), address(market));
        carbon.grantRole(carbon.RETIREMENT_ROLE(), address(retirement));
        market.grantRole(market.OPERATOR_ROLE(), address(governor));
        p2p.grantRole(p2p.OPERATOR_ROLE(), address(governor));
        treasury.grantRole(treasury.OPERATOR_ROLE(), address(governor));
        governor.grantRole(governor.GUARDIAN_ROLE(), guardian);
        oracle.grantRole(oracle.GUARDIAN_ROLE(), guardian);

        // zone + participants
        vm.prank(officer);
        compliance.setZoneAllowed(ZONE_UAE, true);
        vm.prank(producer);
        registry.register(TaqaRegistry.Role.Producer, ZONE_UAE);
        vm.prank(consumer);
        registry.register(TaqaRegistry.Role.Consumer, ZONE_UAE);
        vm.prank(auditor);
        registry.register(TaqaRegistry.Role.Auditor, ZONE_UAE);

        // funds
        aeds.setMinter(address(this));
        aeds.mint(consumer, 1_000_000 ether);
        vm.prank(consumer);
        aeds.approve(address(market), 1_000_000 ether);
        vm.prank(consumer);
        aeds.approve(address(p2p), 1_000_000 ether);

        // oracle prices: energy 0.5 AED/kWh; carbon 40 AED/tonne
        oracle.postPrice(address(aeds), 500_000_000_000_000_000); // 0.5e18

        // a producer meter + attested production → 5 RECs
        vm.prank(producer);
        meterId = meters.registerMeter(bytes32("meter-001"), 10_000);
        vm.prank(auditor);
        meters.attestProduction(meterId, 5_000); // 5,000 kWh → 5 RECs
    }
}
