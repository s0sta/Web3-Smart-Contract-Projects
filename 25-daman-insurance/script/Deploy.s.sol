// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
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

/// @title DeployDaman
/// @notice Deploys the complete mutual: the registry, the EMA oracle with a
///         flight-delay condition, the actuarial pricing desk, the treasury
///         (20% reserve), per-line premium pools, the policy lifecycle, the
///         claims desk, the parametric desk (6% rate), reinsurance (15%
///         cession) and the surplus engine under the governor.
contract DeployDaman is Script {
    function run() external {
        uint256 deployerKey = vm.envOr(
            "DEPLOYER_PRIVATE_KEY",
            vm.envOr(
                "PRIVATE_KEY",
                uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
            )
        );
        address deployer = vm.addr(deployerKey);
        address officer = vm.envOr("COMPLIANCE_OFFICER", deployer);
        address adjuster2 = vm.envOr("ADJUSTER_2", address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8));
        address adjuster3 = vm.envOr("ADJUSTER_3", address(0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC));
        address guardian = vm.envOr("GUARDIAN", deployer);

        vm.startBroadcast(deployerKey);

        MockStable aeds = new MockStable();
        DamanRegistry registry = new DamanRegistry();
        DamanOracle oracle = new DamanOracle(1 hours, 24 hours);
        DamanPricing pricing = new DamanPricing();
        DamanTreasury treasury = new DamanTreasury(aeds, 2000);
        DamanPremiums premiums = new DamanPremiums(aeds);
        DamanPolicies policies = new DamanPolicies(registry, pricing, premiums, treasury, aeds);
        DamanClaims claims = new DamanClaims(registry, policies, premiums);
        DamanParametric parametric = new DamanParametric(registry, oracle, premiums, treasury, aeds);
        DamanReinsurance reinsurance = new DamanReinsurance(premiums, aeds);
        DamanSurplus surplus = new DamanSurplus(policies, premiums);
        DamanGovernor governor = new DamanGovernor(policies, pricing, premiums, claims, parametric, reinsurance, surplus, treasury, oracle, registry, 100);

        // ---- wiring ----
        registry.grantRole(registry.OFFICER_ROLE(), officer);
        claims.grantRole(claims.ADJUSTER_ROLE(), adjuster2);
        claims.grantRole(claims.ADJUSTER_ROLE(), adjuster3);
        policies.grantRole(policies.OPERATOR_ROLE(), address(claims));
        premiums.grantRole(premiums.CLAIMS_ROLE(), address(claims));
        premiums.grantRole(premiums.PARAMETRIC_ROLE(), address(parametric));
        premiums.grantRole(premiums.REINSURANCE_ROLE(), address(reinsurance));
        premiums.grantRole(premiums.SURPLUS_ROLE(), address(surplus));
        pricing.transferOwnership(address(governor));
        governor.grantRole(governor.GUARDIAN_ROLE(), guardian);
        oracle.grantRole(oracle.GUARDIAN_ROLE(), guardian);

        if (officer == deployer) {
            registry.register(DamanRegistry.Role.Policyholder);
            oracle.addCondition(address(0), DamanOracle.CondType.MeasurementAbove, 180);
        }
        vm.stopBroadcast();

        console2.log("AED-S     :", address(aeds));
        console2.log("Registry  :", address(registry));
        console2.log("Oracle    :", address(oracle), "| condition 0: delay > 180");
        console2.log("Pricing   :", address(pricing));
        console2.log("Treasury  :", address(treasury));
        console2.log("Premiums  :", address(premiums));
        console2.log("Policies  :", address(policies));
        console2.log("Claims    :", address(claims));
        console2.log("Parametric:", address(parametric));
        console2.log("Reinsurance:", address(reinsurance));
        console2.log("Surplus   :", address(surplus));
        console2.log("Governor  :", address(governor));
    }
}
