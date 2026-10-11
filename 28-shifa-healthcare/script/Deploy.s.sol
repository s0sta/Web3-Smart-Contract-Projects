// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockStable} from "../src/MockStable.sol";
import {ShifaRegistry} from "../src/ShifaRegistry.sol";
import {ShifaConsent} from "../src/ShifaConsent.sol";
import {ShifaRecords} from "../src/ShifaRecords.sol";
import {ShifaPrescriptions} from "../src/ShifaPrescriptions.sol";
import {ShifaEmergency} from "../src/ShifaEmergency.sol";
import {ShifaAppointments} from "../src/ShifaAppointments.sol";
import {ShifaTreasury} from "../src/ShifaTreasury.sol";
import {ShifaInsurance} from "../src/ShifaInsurance.sol";
import {ShifaPayments} from "../src/ShifaPayments.sol";
import {ShifaReputation} from "../src/ShifaReputation.sol";
import {ShifaGovernor} from "../src/ShifaGovernor.sol";

/// @title DeployShifa
/// @notice Deploys the whole healthcare platform: the SAR-S settlement stable,
///         the member directory, the consent desk, the record index, electronic
///         prescriptions (1 controlled refill), break-glass emergency access,
///         appointments (2% fee, 1-day cancellation window), the treasury (20%
///         reserve), health insurance (5% premium, reviewers at 2-of-3),
///         payments (1.5% direct / 0.5% copay), reputation and the governor.
contract DeployShifa is Script {
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
        address reviewer1 = vm.envOr("REVIEWER_1", deployer);
        address reviewer2 = vm.envOr("REVIEWER_2", deployer);
        address guardian = vm.envOr("GUARDIAN", deployer);
        uint64 region = uint64(vm.envOr("REGION", uint256(682))); // Saudi Arabia

        vm.startBroadcast(deployerKey);

        MockStable sar = new MockStable();
        ShifaRegistry registry = new ShifaRegistry();
        ShifaConsent consent = new ShifaConsent(registry);
        ShifaRecords records = new ShifaRecords(registry, consent);
        ShifaPrescriptions prescriptions = new ShifaPrescriptions(registry, consent, 1);
        ShifaEmergency emergency = new ShifaEmergency(registry, consent);
        ShifaTreasury treasury = new ShifaTreasury(sar, 2000);
        ShifaAppointments appointments = new ShifaAppointments(registry, treasury, sar, 1 days);
        ShifaInsurance insurance = new ShifaInsurance(registry, treasury, sar, 500);
        ShifaPayments payments = new ShifaPayments(registry, insurance, treasury, sar);
        ShifaReputation reputation = new ShifaReputation(registry, appointments);
        ShifaGovernor governor = new ShifaGovernor(
            registry,
            consent,
            records,
            prescriptions,
            appointments,
            insurance,
            payments,
            emergency,
            reputation,
            treasury,
            300
        );

        // ---- wiring ----
        registry.grantRole(registry.OFFICER_ROLE(), officer);
        consent.grantRole(consent.EMERGENCY_ROLE(), address(emergency));
        emergency.grantRole(emergency.REVIEWER_ROLE(), reviewer1);
        emergency.grantRole(emergency.REVIEWER_ROLE(), reviewer2);
        insurance.grantRole(insurance.REVIEWER_ROLE(), reviewer1);
        insurance.grantRole(insurance.REVIEWER_ROLE(), reviewer2);
        governor.grantRole(governor.GUARDIAN_ROLE(), guardian);
        treasury.grantRole(treasury.GUARDIAN_ROLE(), guardian);
        appointments.grantRole(appointments.DEFAULT_ADMIN_ROLE(), address(governor));
        insurance.grantRole(insurance.DEFAULT_ADMIN_ROLE(), address(governor));
        payments.grantRole(payments.DEFAULT_ADMIN_ROLE(), address(governor));
        treasury.grantRole(treasury.OPERATOR_ROLE(), address(governor));

        // the deployer becomes the first verified doctor so the demo has a clinician
        registry.register(ShifaRegistry.Role.Doctor, region, keccak256("s0sta-license"));
        registry.setKyc(deployer, ShifaRegistry.KycTier.Verified);
        vm.stopBroadcast();

        console2.log("SAR-S       :", address(sar));
        console2.log("Registry    :", address(registry));
        console2.log("Consent     :", address(consent));
        console2.log("Records     :", address(records));
        console2.log("Prescriptions:", address(prescriptions));
        console2.log("Emergency   :", address(emergency));
        console2.log("Appointments:", address(appointments));
        console2.log("Treasury    :", address(treasury));
        console2.log("Insurance   :", address(insurance));
        console2.log("Payments    :", address(payments));
        console2.log("Reputation  :", address(reputation));
        console2.log("Governor    :", address(governor));
    }
}
