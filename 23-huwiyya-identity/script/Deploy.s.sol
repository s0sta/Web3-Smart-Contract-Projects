// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockStable} from "../src/MockStable.sol";
import {HuwiyyaRegistry} from "../src/HuwiyyaRegistry.sol";
import {HuwiyyaSchema} from "../src/HuwiyyaSchema.sol";
import {HuwiyyaTreasury} from "../src/HuwiyyaTreasury.sol";
import {HuwiyyaCredentials} from "../src/HuwiyyaCredentials.sol";
import {HuwiyyaAttestations} from "../src/HuwiyyaAttestations.sol";
import {HuwiyyaReputation} from "../src/HuwiyyaReputation.sol";
import {HuwiyyaGates} from "../src/HuwiyyaGates.sol";
import {HuwiyyaRecovery} from "../src/HuwiyyaRecovery.sol";
import {HuwiyyaGovernor} from "../src/HuwiyyaGovernor.sol";

/// @title DeployHuwiyya
/// @notice Deploys the complete identity stack: the DID registry, the schema
///         registry (IdentityCard), the treasury, the credential ledger (5 AED-S
///         issuance fee), the attestation desk, the reputation engine, the access
///         gates, social recovery (2-of-3, 1-day delay) and the governor.
contract DeployHuwiyya is Script {
    function run() external {
        uint256 deployerKey = vm.envOr(
            "DEPLOYER_PRIVATE_KEY",
            vm.envOr(
                "PRIVATE_KEY",
                uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
            )
        );
        address deployer = vm.addr(deployerKey);
        address issuer = vm.envOr("ISSUER", deployer);
        address attestor = vm.envOr("ATTESTOR", deployer);
        address officer = vm.envOr("COMPLIANCE_OFFICER", deployer);
        address guardian = vm.envOr("GUARDIAN", deployer);

        vm.startBroadcast(deployerKey);

        MockStable feeToken = new MockStable();
        HuwiyyaRegistry registry = new HuwiyyaRegistry();
        HuwiyyaSchema schemas = new HuwiyyaSchema();
        HuwiyyaTreasury treasury = new HuwiyyaTreasury(feeToken, 2000);
        HuwiyyaCredentials credentials = new HuwiyyaCredentials(registry, schemas, treasury, feeToken);
        HuwiyyaAttestations attestations = new HuwiyyaAttestations(registry);
        HuwiyyaReputation reputation = new HuwiyyaReputation(attestations);
        HuwiyyaGates gates = new HuwiyyaGates(registry, credentials, reputation);
        HuwiyyaRecovery recovery = new HuwiyyaRecovery(registry);
        HuwiyyaGovernor governor = new HuwiyyaGovernor(reputation, registry, credentials, attestations, gates, recovery, treasury, schemas, 300);

        // ---- wiring ----
        registry.grantRole(registry.RECOVERY_ROLE(), address(recovery));
        registry.grantRole(registry.OFFICER_ROLE(), officer);
        credentials.grantRole(credentials.ISSUER_ROLE(), issuer);
        credentials.grantRole(credentials.DEFAULT_ADMIN_ROLE(), address(governor));
        attestations.grantRole(attestations.ATTESTOR_ROLE(), attestor);
        attestations.setWeight(attestor, 10_000);
        governor.grantRole(governor.GUARDIAN_ROLE(), guardian);

        // the IdentityCard schema
        string[] memory names = new string[](3);
        names[0] = "name";
        names[1] = "dob";
        names[2] = "nationality";
        HuwiyyaSchema.FieldType[] memory types = new HuwiyyaSchema.FieldType[](3);
        types[0] = HuwiyyaSchema.FieldType.String;
        types[1] = HuwiyyaSchema.FieldType.Date;
        types[2] = HuwiyyaSchema.FieldType.String;
        schemas.publishSchema("IdentityCard", 1, names, types);

        if (officer == deployer) {
            registry.createDid(keccak256("issuer-doc"));
        }
        vm.stopBroadcast();

        console2.log("Fee token :", address(feeToken));
        console2.log("Registry  :", address(registry));
        console2.log("Schemas   :", address(schemas));
        console2.log("Treasury  :", address(treasury));
        console2.log("Credentials:", address(credentials));
        console2.log("Attestations:", address(attestations));
        console2.log("Reputation:", address(reputation));
        console2.log("Gates     :", address(gates));
        console2.log("Recovery  :", address(recovery));
        console2.log("Governor  :", address(governor));
    }
}
