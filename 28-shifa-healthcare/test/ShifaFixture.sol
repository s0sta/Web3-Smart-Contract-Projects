// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
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

/// @notice The complete platform wiring: an SAR-S settlement stable, a patient,
///         a doctor, a clinic, a pharmacist and an insurer (all verified), two
///         medical reviewers, the consent desk, the record index, prescriptions,
///         appointments (2% fee), the treasury (20% reserve), insurance (5%
///         premium, 20% copay), payments (1.5% / 0.5% fees), break-glass
///         emergency access, reputation and the governor.
abstract contract ShifaFixture is Test {
    MockStable internal sar;
    ShifaRegistry internal registry;
    ShifaConsent internal consent;
    ShifaRecords internal records;
    ShifaPrescriptions internal prescriptions;
    ShifaEmergency internal emergency;
    ShifaAppointments internal appointments;
    ShifaTreasury internal treasury;
    ShifaInsurance internal insurance;
    ShifaPayments internal payments;
    ShifaReputation internal reputation;
    ShifaGovernor internal governor;

    address internal officer = address(0xC);
    address internal guardian = address(0x6);
    address internal patient = address(0xA);
    address internal patient2 = address(0xB);
    address internal doctor = address(0xD);
    address internal pharmacist = address(0xE);
    address internal insurer = address(0xF);
    address internal reviewer1 = address(0x11);
    address internal reviewer2 = address(0x22);
    address internal outsider = address(0x99);

    uint64 internal constant REGION = 682; // Saudi Arabia
    uint256 internal appointmentId;
    uint256 internal claimId;

    function setUp() public virtual {
        sar = new MockStable();
        registry = new ShifaRegistry();
        consent = new ShifaConsent(registry);
        records = new ShifaRecords(registry, consent);
        prescriptions = new ShifaPrescriptions(registry, consent, 1);
        emergency = new ShifaEmergency(registry, consent);
        treasury = new ShifaTreasury(sar, 2000);
        appointments = new ShifaAppointments(registry, treasury, sar, 1 days);
        insurance = new ShifaInsurance(registry, treasury, sar, 500); // 5%
        payments = new ShifaPayments(registry, insurance, treasury, sar);
        reputation = new ShifaReputation(registry, appointments);
        governor = new ShifaGovernor(registry, consent, records, prescriptions, appointments, insurance, payments, emergency, reputation, treasury, 300);

        // wiring
        registry.grantRole(registry.OFFICER_ROLE(), officer);
        consent.grantRole(consent.EMERGENCY_ROLE(), address(emergency));
        emergency.grantRole(emergency.REVIEWER_ROLE(), reviewer1);
        emergency.grantRole(emergency.REVIEWER_ROLE(), reviewer2);
        insurance.grantRole(insurance.REVIEWER_ROLE(), reviewer1);
        insurance.grantRole(insurance.REVIEWER_ROLE(), reviewer2);
        appointments.grantRole(appointments.DEFAULT_ADMIN_ROLE(), address(governor));
        appointments.setCancellationWindow(1 days);
        insurance.grantRole(insurance.DEFAULT_ADMIN_ROLE(), address(governor));
        payments.grantRole(payments.DEFAULT_ADMIN_ROLE(), address(governor));
        governor.grantRole(governor.GUARDIAN_ROLE(), guardian);
        treasury.grantRole(treasury.GUARDIAN_ROLE(), guardian);

        // members
        vm.prank(patient);
        registry.register(ShifaRegistry.Role.Patient, REGION, bytes32(0));
        vm.prank(patient2);
        registry.register(ShifaRegistry.Role.Patient, REGION, bytes32(0));
        vm.prank(doctor);
        registry.register(ShifaRegistry.Role.Doctor, REGION, bytes32("license-doctor"));
        vm.prank(pharmacist);
        registry.register(ShifaRegistry.Role.Pharmacist, REGION, bytes32("license-pharmacy"));
        vm.prank(insurer);
        registry.register(ShifaRegistry.Role.Insurer, REGION, bytes32("license-insurer"));

        // verify the providers
        vm.startPrank(officer);
        registry.setKyc(doctor, ShifaRegistry.KycTier.Verified);
        registry.setKyc(pharmacist, ShifaRegistry.KycTier.Verified);
        registry.setKyc(insurer, ShifaRegistry.KycTier.Verified);
        vm.stopPrank();

        // money
        sar.setMinter(address(this));
        sar.mint(patient, 100_000 ether);
        sar.mint(patient2, 100_000 ether);
        vm.prank(patient);
        sar.approve(address(appointments), 100_000 ether);
        vm.prank(patient);
        sar.approve(address(payments), 100_000 ether);
        vm.prank(patient);
        sar.approve(address(insurance), 100_000 ether);
        vm.prank(patient2);
        sar.approve(address(appointments), 100_000 ether);

        // the patient funds the insurance pool so claims can be paid
        sar.mint(address(insurance), 200_000 ether);

        // a completed visit so reputation/rating tests have a base
        vm.prank(patient);
        appointmentId = appointments.book(doctor, uint64(block.timestamp + 2 days), 500 ether);
    }

    function _completeVisit() internal {
        vm.prank(doctor);
        appointments.complete(appointmentId);
    }

    function _openInsurance() internal returns (uint256 planId) {
        vm.prank(patient);
        (planId, ) = insurance.subscribe(insurer, 10_000 ether, 2000, 365);
    }

    function _approvedClaim() internal returns (uint256 id) {
        _openInsurance();
        vm.prank(insurer);
        uint256 preAuthId = insurance.preAuthorize(0, doctor, bytes32("consult"), 1_000 ether, 30);
        vm.prank(doctor);
        id = insurance.fileClaim(preAuthId, 1_000 ether);
        vm.prank(reviewer1);
        insurance.voteClaim(id, true);
        vm.prank(reviewer2);
        insurance.voteClaim(id, true);
    }
}
