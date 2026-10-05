// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {MockStable} from "../src/MockStable.sol";
import {DamanRegistry} from "../src/DamanRegistry.sol";
import {DamanOracle} from "../src/DamanOracle.sol";
import {DamanPricing, DamanLines} from "../src/DamanPricing.sol";
import {DamanTreasury} from "../src/DamanTreasury.sol";
import {DamanPremiums} from "../src/DamanPremiums.sol";
import {DamanPolicies} from "../src/DamanPolicies.sol";
import {DamanClaims} from "../src/DamanClaims.sol";
import {DamanParametric} from "../src/DamanParametric.sol";
import {DamanReinsurance} from "../src/DamanReinsurance.sol";
import {DamanSurplus} from "../src/DamanSurplus.sol";
import {DamanGovernor} from "../src/DamanGovernor.sol";

/// @notice The complete mutual: AED-S premiums, a registry with a policyholder
///         and two adjusters, the EMA oracle with a flight-delay condition
///         (>180 minutes), the actuarial pricing desk, the treasury (20%
///         reserve), per-line premium pools, the policy lifecycle, the claims
///         desk, the parametric desk (6% rate), reinsurance (15% cession) and
///         the surplus engine — all under the governor (10% quorum).
abstract contract DamanFixture is Test {
    MockStable internal aeds;
    DamanRegistry internal registry;
    DamanOracle internal oracle;
    DamanPricing internal pricing;
    DamanTreasury internal treasury;
    DamanPremiums internal premiums;
    DamanPolicies internal policies;
    DamanClaims internal claims;
    DamanParametric internal parametric;
    DamanReinsurance internal reinsurance;
    DamanSurplus internal surplus;
    DamanGovernor internal governor;

    address internal officer = address(0xC);
    address internal guardian = address(0x6);
    address internal holder = address(0xA);
    address internal holder2 = address(0xB);
    address internal adjuster1 = address(0xF1);
    address internal adjuster2 = address(0xF2);
    address internal outsider = address(0x99);

    uint256 internal conditionId;
    uint256 internal policyId;

    function setUp() public virtual {
        aeds = new MockStable();
        registry = new DamanRegistry();
        oracle = new DamanOracle(1 hours, 24 hours);
        pricing = new DamanPricing();
        treasury = new DamanTreasury(aeds, 2000);
        premiums = new DamanPremiums(aeds);
        policies = new DamanPolicies(registry, pricing, premiums, treasury, aeds);
        claims = new DamanClaims(registry, policies, premiums);
        parametric = new DamanParametric(registry, oracle, premiums, treasury, aeds);
        reinsurance = new DamanReinsurance(premiums, aeds);
        surplus = new DamanSurplus(policies, premiums);
        governor = new DamanGovernor(policies, pricing, premiums, claims, parametric, reinsurance, surplus, treasury, oracle, registry, 0);
        pricing.transferOwnership(address(governor));

        // wiring
        registry.grantRole(registry.OFFICER_ROLE(), officer);
        claims.grantRole(claims.ADJUSTER_ROLE(), adjuster1);
        claims.grantRole(claims.ADJUSTER_ROLE(), adjuster2);
        policies.grantRole(policies.OPERATOR_ROLE(), address(claims));
        premiums.grantRole(premiums.CLAIMS_ROLE(), address(claims));
        premiums.grantRole(premiums.PARAMETRIC_ROLE(), address(parametric));
        premiums.grantRole(premiums.REINSURANCE_ROLE(), address(reinsurance));
        premiums.grantRole(premiums.SURPLUS_ROLE(), address(surplus));
        governor.grantRole(governor.GUARDIAN_ROLE(), guardian);
        oracle.grantRole(oracle.GUARDIAN_ROLE(), guardian);

        // participants
        vm.prank(holder);
        registry.register(DamanRegistry.Role.Policyholder);
        vm.prank(holder2);
        registry.register(DamanRegistry.Role.Policyholder);
        vm.prank(adjuster1);
        registry.register(DamanRegistry.Role.Adjuster);
        vm.prank(adjuster2);
        registry.register(DamanRegistry.Role.Adjuster);

        // funds
        aeds.setMinter(address(this));
        aeds.mint(holder, 1_000_000 ether);
        vm.prank(holder);
        aeds.approve(address(policies), 1_000_000 ether);
        vm.prank(holder);
        aeds.approve(address(parametric), 1_000_000 ether);
        aeds.mint(holder2, 1_000_000 ether);
        vm.prank(holder2);
        aeds.approve(address(policies), 1_000_000 ether);

        // seed the line pools and the reinsurance pool
        aeds.mint(address(this), 1_000_000 ether);
        aeds.approve(address(premiums), 1_000_000 ether);
        premiums.fundPool(DamanLines.Line.Travel, 500_000 ether);
        premiums.fundPool(DamanLines.Line.FlightDelay, 100_000 ether);
        aeds.approve(address(reinsurance), 100_000 ether);
        reinsurance.fundPool(DamanLines.Line.Travel, 100_000 ether);

        // a flight-delay condition: delay > 180 minutes
        conditionId = oracle.addCondition(address(0), DamanOracle.CondType.MeasurementAbove, 180);

        // a Travel policy for the holder
        vm.prank(holder);
        policyId = policies.buyPolicy(DamanLines.Line.Travel, DamanPricing.RiskClass.Standard, 10_000 ether, 30);
    }
}
