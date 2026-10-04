// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockStable} from "../src/MockStable.sol";
import {SilsilaRegistry} from "../src/SilsilaRegistry.sol";
import {SilsilaCompliance} from "../src/SilsilaCompliance.sol";
import {SilsilaOrders} from "../src/SilsilaOrders.sol";
import {SilsilaShipments} from "../src/SilsilaShipments.sol";
import {SilsilaQuality} from "../src/SilsilaQuality.sol";
import {SilsilaPayments} from "../src/SilsilaPayments.sol";
import {SilsilaCargoInsurance} from "../src/SilsilaCargoInsurance.sol";
import {SilsilaReputation} from "../src/SilsilaReputation.sol";
import {SilsilaTreasury} from "../src/SilsilaTreasury.sol";
import {SilsilaOracle} from "../src/SilsilaOracle.sol";
import {SilsilaGovernor} from "../src/SilsilaGovernor.sol";

/// @title DeploySilsila
/// @notice Deploys the complete trade network: the business registry, export-
///         control compliance, purchase orders, shipment tracking, quality
///         inspections, milestone payments (30/70, 0.5% fee, 3% carrier, 5%
///         late penalty), cargo insurance (2% premium), reputation, the
///         treasury, the EMA oracle and the governor.
contract DeploySilsila is Script {
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
        SilsilaRegistry registry = new SilsilaRegistry();
        SilsilaCompliance compliance = new SilsilaCompliance(registry);
        SilsilaOrders orders = new SilsilaOrders(registry, compliance);
        SilsilaShipments shipments = new SilsilaShipments(registry, orders);
        SilsilaQuality quality = new SilsilaQuality(registry, shipments, orders);
        SilsilaTreasury treasury = new SilsilaTreasury(aeds, 2000);
        SilsilaPayments payments = new SilsilaPayments(registry, orders, shipments, treasury, aeds);
        SilsilaCargoInsurance cargo = new SilsilaCargoInsurance(registry, orders, shipments, aeds);
        SilsilaReputation reputation = new SilsilaReputation(registry, shipments, quality);
        SilsilaOracle oracle = new SilsilaOracle(1 hours, 24 hours);
        SilsilaGovernor governor = new SilsilaGovernor(registry, compliance, orders, shipments, quality, payments, cargo, reputation, treasury, oracle, 300);

        // ---- wiring ----
        registry.grantRole(registry.OFFICER_ROLE(), officer);
        compliance.grantRole(compliance.OFFICER_ROLE(), officer);
        payments.grantRole(payments.OPERATOR_ROLE(), address(governor));
        cargo.grantRole(cargo.ADJUSTER_ROLE(), adjuster2);
        cargo.grantRole(cargo.ADJUSTER_ROLE(), adjuster3);
        governor.grantRole(governor.GUARDIAN_ROLE(), guardian);
        oracle.grantRole(oracle.GUARDIAN_ROLE(), guardian);

        if (officer == deployer) {
            compliance.setRegionAllowed(784, true); // UAE
            compliance.setRegionAllowed(840, true); // US
            registry.register(SilsilaRegistry.Role.Financier, 784);
        }
        vm.stopBroadcast();

        console2.log("AED-S     :", address(aeds));
        console2.log("Registry  :", address(registry));
        console2.log("Compliance:", address(compliance));
        console2.log("Orders    :", address(orders));
        console2.log("Shipments :", address(shipments));
        console2.log("Quality   :", address(quality));
        console2.log("Payments  :", address(payments));
        console2.log("Cargo     :", address(cargo));
        console2.log("Reputation:", address(reputation));
        console2.log("Treasury  :", address(treasury));
        console2.log("Oracle    :", address(oracle));
        console2.log("Governor  :", address(governor));
    }
}
