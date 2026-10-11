// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ShifaFixture} from "./ShifaFixture.sol";
import {ShifaRegistry} from "../src/ShifaRegistry.sol";
import {ShifaConsent} from "../src/ShifaConsent.sol";
import {ShifaScopes} from "../src/ShifaScopes.sol";
import {ShifaRecords} from "../src/ShifaRecords.sol";
import {ShifaPrescriptions} from "../src/ShifaPrescriptions.sol";
import {ShifaEmergency} from "../src/ShifaEmergency.sol";
import {ShifaAppointments} from "../src/ShifaAppointments.sol";
import {ShifaTreasury} from "../src/ShifaTreasury.sol";
import {ShifaInsurance} from "../src/ShifaInsurance.sol";
import {ShifaPayments} from "../src/ShifaPayments.sol";
import {ShifaReputation} from "../src/ShifaReputation.sol";
import {ShifaGovernor} from "../src/ShifaGovernor.sol";

contract ShifaRegistryTest is ShifaFixture {
    function test_Register_AssignsRole() public {
        assertEq(uint8(registry.roleOf(patient)), uint8(ShifaRegistry.Role.Patient));
        assertEq(uint8(registry.roleOf(doctor)), uint8(ShifaRegistry.Role.Doctor));
        assertEq(registry.memberCount(), 5);
    }

    function test_Register_Twice_Reverts() public {
        vm.prank(patient);
        vm.expectRevert(abi.encodeWithSelector(ShifaRegistry.AlreadyRegistered.selector, patient));
        registry.register(ShifaRegistry.Role.Patient, REGION, bytes32(0));
    }

    function test_VerifiedProvider_RequiresKyc() public {
        assertTrue(registry.isVerifiedProvider(doctor));
        // a patient is active but is not a provider
        assertFalse(registry.isVerifiedProvider(patient));
    }

    function test_Freeze_OfficerOnly() public {
        vm.prank(outsider);
        vm.expectRevert(ShifaRegistry.NotOfficer.selector);
        registry.setFrozen(doctor, true);
        vm.prank(officer);
        registry.setFrozen(doctor, true);
        assertFalse(registry.isActive(doctor));
        assertFalse(registry.isVerifiedProvider(doctor));
    }

    function test_Sanction_BlocksCare() public {
        vm.prank(officer);
        registry.setSanctioned(doctor, true);
        assertFalse(registry.isVerifiedProvider(doctor));
    }

    function test_UnknownAccount_Reverts() public {
        vm.prank(officer);
        vm.expectRevert(abi.encodeWithSelector(ShifaRegistry.UnknownAccount.selector, outsider));
        registry.setKyc(outsider, ShifaRegistry.KycTier.Verified);
    }
}

contract ShifaConsentTest is ShifaFixture {
    function test_Grant_And_HasConsent() public {
        vm.prank(patient);
        consent.grant(doctor, ShifaScopes.RECORDS, uint64(block.timestamp + 30 days));
        assertTrue(consent.hasConsent(patient, doctor, ShifaScopes.RECORDS));
        (uint8 scope, , , bool active) = consent.grants(patient, doctor);
        assertEq(scope, ShifaScopes.RECORDS);
        assertTrue(active);
    }

    function test_Grant_ZeroScope_Reverts() public {
        vm.prank(patient);
        vm.expectRevert(ShifaConsent.EmptyScope.selector);
        consent.grant(doctor, 0, uint64(block.timestamp + 30 days));
    }

    function test_Grant_ExpiredDate_Reverts() public {
        vm.prank(patient);
        vm.expectRevert(ShifaConsent.ExpiryInPast.selector);
        consent.grant(doctor, ShifaScopes.RECORDS, uint64(block.timestamp));
    }

    function test_Revoke_RemovesConsent() public {
        vm.prank(patient);
        consent.grant(doctor, ShifaScopes.ALL, uint64(block.timestamp + 30 days));
        vm.prank(patient);
        consent.revoke(doctor);
        assertFalse(consent.hasConsent(patient, doctor, ShifaScopes.RECORDS));
    }

    function test_Expiry_EndsConsent() public {
        vm.prank(patient);
        consent.grant(doctor, ShifaScopes.RECORDS, uint64(block.timestamp + 1 days));
        vm.warp(block.timestamp + 2 days);
        assertFalse(consent.hasConsent(patient, doctor, ShifaScopes.RECORDS));
    }

    function test_EmergencyGrant_EmergencyOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        consent.emergencyGrant(patient, doctor, 24);
        vm.prank(address(emergency));
        uint64 expiresAt = consent.emergencyGrant(patient, doctor, 24);
        assertGt(expiresAt, block.timestamp);
        assertTrue(consent.hasConsent(patient, doctor, ShifaScopes.RECORDS));
        assertFalse(consent.hasConsent(patient, doctor, ShifaScopes.INSURANCE));
    }

    function test_RequireConsent_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(ShifaConsent.NoConsent.selector, patient, doctor, ShifaScopes.RECORDS));
        consent.requireConsent(patient, doctor, ShifaScopes.RECORDS);
    }
}

contract ShifaRecordsTest is ShifaFixture {
    function test_Create_ClinicianOnly() public {
        vm.prank(patient);
        vm.expectRevert(ShifaRecords.NotClinician.selector);
        records.createRecord(patient, ShifaRecords.Kind.Lab, bytes32("lab-1"));
    }

    function test_Create_And_ReadByPatient() public {
        vm.prank(doctor);
        uint256 id = records.createRecord(patient, ShifaRecords.Kind.Lab, bytes32("lab-1"));
        assertEq(records.recordCount(), 1);
        vm.prank(patient);
        assertEq(records.readRecord(id), bytes32("lab-1"));
    }

    function test_Read_RequiresConsent() public {
        vm.prank(doctor);
        uint256 id = records.createRecord(patient, ShifaRecords.Kind.Imaging, bytes32("xray-1"));
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(ShifaRecords.NotAllowedToRead.selector, id, outsider));
        records.readRecord(id);
    }

    function test_Read_WithConsent() public {
        vm.prank(doctor);
        uint256 id = records.createRecord(patient, ShifaRecords.Kind.Note, bytes32("note-1"));
        // a second clinic joins the network and the patient shares the record
        vm.prank(outsider);
        registry.register(ShifaRegistry.Role.Clinic, REGION, bytes32("license-clinic"));
        vm.prank(patient);
        consent.grant(outsider, ShifaScopes.RECORDS, uint64(block.timestamp + 7 days));
        assertTrue(records.canRead(id, outsider));
        vm.prank(outsider);
        assertEq(records.readRecord(id), bytes32("note-1"));
    }

    function test_Amend_AuthorOnly() public {
        vm.prank(doctor);
        uint256 id = records.createRecord(patient, ShifaRecords.Kind.Note, bytes32("note-1"));
        vm.prank(patient);
        vm.expectRevert(abi.encodeWithSelector(ShifaRecords.NotAuthor.selector, id));
        records.amendRecord(id, bytes32("note-2"));
        vm.prank(doctor);
        records.amendRecord(id, bytes32("note-2"));
        ( , , , bytes32 contentHash, , bool amended) = records.records(id);
        assertEq(contentHash, bytes32("note-2"));
        assertTrue(amended);
    }

    function test_EmptyHash_Reverts() public {
        vm.prank(doctor);
        vm.expectRevert(ShifaRecords.EmptyHash.selector);
        records.createRecord(patient, ShifaRecords.Kind.Note, bytes32(0));
    }
}

contract ShifaPrescriptionsTest is ShifaFixture {
    function _issueDefault() internal returns (uint256) {
        vm.prank(doctor);
        return prescriptions.issue(patient, bytes32("amoxicillin"), 500, 2, 30, false);
    }

    function test_Issue_ClinicianOnly() public {
        vm.prank(patient);
        vm.expectRevert(ShifaPrescriptions.NotClinician.selector);
        prescriptions.issue(patient, bytes32("drug"), 100, 1, 30, false);
    }

    function test_Issue_StoresDose() public {
        uint256 rxId = _issueDefault();
        ( , , bytes32 drugHash, uint16 doseMg, uint8 refills, , , , bool controlled, ) = prescriptions.prescriptions(rxId);
        assertEq(drugHash, bytes32("amoxicillin"));
        assertEq(doseMg, 500);
        assertEq(refills, 2);
        assertFalse(controlled);
    }

    function test_Dispense_RequiresConsent() public {
        uint256 rxId = _issueDefault();
        vm.prank(pharmacist);
        vm.expectRevert(abi.encodeWithSelector(ShifaPrescriptions.NotAllowed.selector, rxId, pharmacist));
        prescriptions.dispense(rxId);
    }

    function test_Dispense_WithConsent_CountsRefills() public {
        uint256 rxId = _issueDefault();
        vm.prank(patient);
        consent.grant(pharmacist, ShifaScopes.PRESCRIPTIONS, uint64(block.timestamp + 30 days));
        vm.prank(pharmacist);
        prescriptions.dispense(rxId);
        assertEq(prescriptions.refillsLeft(rxId), 1);
        vm.prank(pharmacist);
        prescriptions.dispense(rxId);
        assertEq(prescriptions.refillsLeft(rxId), 0);
    }

    function test_Dispense_NoRefillsLeft() public {
        uint256 rxId = _issueDefault();
        vm.prank(patient);
        consent.grant(pharmacist, ShifaScopes.ALL, uint64(block.timestamp + 30 days));
        vm.prank(pharmacist);
        prescriptions.dispense(rxId);
        vm.prank(pharmacist);
        prescriptions.dispense(rxId);
        vm.prank(pharmacist);
        vm.expectRevert(abi.encodeWithSelector(ShifaPrescriptions.NoRefillsLeft.selector, rxId));
        prescriptions.dispense(rxId);
    }

    function test_Dispense_Expired() public {
        uint256 rxId = _issueDefault();
        vm.prank(patient);
        consent.grant(pharmacist, ShifaScopes.ALL, uint64(block.timestamp + 60 days));
        vm.warp(block.timestamp + 31 days);
        vm.prank(pharmacist);
        vm.expectRevert(abi.encodeWithSelector(ShifaPrescriptions.ExpiredPrescription.selector, rxId, uint64(block.timestamp - 1 days)));
        prescriptions.dispense(rxId);
    }

    function test_Controlled_CapEnforced() public {
        vm.prank(doctor);
        vm.expectRevert(abi.encodeWithSelector(ShifaPrescriptions.ControlledLimit.selector, 0, 1));
        prescriptions.issue(patient, bytes32("morphine"), 10, 5, 30, true);
    }

    function test_NotPharmacist_Reverts() public {
        uint256 rxId = _issueDefault();
        vm.prank(patient);
        consent.grant(doctor, ShifaScopes.ALL, uint64(block.timestamp + 30 days));
        vm.prank(doctor);
        vm.expectRevert(ShifaPrescriptions.NotPharmacist.selector);
        prescriptions.dispense(rxId);
    }

    function test_Cancel_DoctorOnly() public {
        uint256 rxId = _issueDefault();
        vm.prank(patient);
        vm.expectRevert(abi.encodeWithSelector(ShifaPrescriptions.NotAllowed.selector, rxId, patient));
        prescriptions.cancel(rxId);
        vm.prank(doctor);
        prescriptions.cancel(rxId);
        vm.prank(patient);
        consent.grant(pharmacist, ShifaScopes.ALL, uint64(block.timestamp + 30 days));
        vm.prank(pharmacist);
        vm.expectRevert(abi.encodeWithSelector(ShifaPrescriptions.CanceledPrescription.selector, rxId));
        prescriptions.dispense(rxId);
    }
}

contract ShifaEmergencyTest is ShifaFixture {
    function test_Open_ClinicianOnly() public {
        vm.prank(patient);
        vm.expectRevert(ShifaEmergency.NotClinician.selector);
        emergency.openCase(patient, "trauma", 24);
    }

    function test_Open_GivesTemporaryAccess() public {
        vm.prank(doctor);
        (uint256 caseId, uint64 expiresAt) = emergency.openCase(patient, "trauma", 24);
        assertTrue(emergency.isOpen(caseId));
        assertGt(expiresAt, block.timestamp);
        assertTrue(consent.hasConsent(patient, doctor, ShifaScopes.RECORDS));
        vm.warp(block.timestamp + 25 hours);
        assertFalse(emergency.isOpen(caseId));
    }

    function test_Open_DurationCapped() public {
        vm.prank(doctor);
        vm.expectRevert(abi.encodeWithSelector(ShifaEmergency.DurationTooLong.selector, uint64(100), uint64(72)));
        emergency.openCase(patient, "trauma", 100);
    }

    function test_Review_Once() public {
        vm.prank(doctor);
        (uint256 caseId, ) = emergency.openCase(patient, "trauma", 24);
        vm.prank(outsider);
        vm.expectRevert();
        emergency.review(caseId, true);
        vm.prank(reviewer1);
        emergency.review(caseId, true);
        ( , , , , , bool reviewed, bool upheld) = emergency.cases(caseId);
        assertTrue(reviewed);
        assertTrue(upheld);
        vm.prank(reviewer2);
        vm.expectRevert(abi.encodeWithSelector(ShifaEmergency.AlreadyReviewed.selector, caseId));
        emergency.review(caseId, false);
    }

    function test_RecordsReadable_DuringEmergency() public {
        vm.prank(doctor);
        uint256 recordId = records.createRecord(patient, ShifaRecords.Kind.Allergy, bytes32("penicillin"));
        vm.prank(doctor);
        emergency.openCase(patient, "anaphylaxis", 6);
        assertTrue(records.canRead(recordId, doctor));
    }
}

contract ShifaAppointmentsTest is ShifaFixture {
    function test_Book_EscrowsDeposit() public {
        (address p, address provider, , uint256 deposit, ShifaAppointments.Status status, ) = appointments.appointments(appointmentId);
        assertEq(p, patient);
        assertEq(provider, doctor);
        assertEq(deposit, 500 ether);
        assertEq(uint8(status), uint8(ShifaAppointments.Status.Booked));
        assertEq(sar.balanceOf(address(appointments)), 500 ether);
    }

    function test_Book_NonClinician_Reverts() public {
        vm.prank(patient);
        vm.expectRevert(ShifaAppointments.NotClinicianProvider.selector);
        appointments.book(patient2, uint64(block.timestamp + 2 days), 100 ether);
    }

    function test_Book_PastSlot_Reverts() public {
        vm.prank(patient);
        vm.expectRevert(abi.encodeWithSelector(ShifaAppointments.SlotInPast.selector, uint64(block.timestamp)));
        appointments.book(doctor, uint64(block.timestamp), 100 ether);
    }

    function test_Complete_PaysProvider_MinusFee() public {
        _completeVisit();
        // 500 − 2% = 490 to the doctor
        assertEq(sar.balanceOf(doctor), 490 ether);
        assertEq(sar.balanceOf(address(treasury)), 10 ether);
        assertTrue(appointments.hasCompleted(patient, doctor));
        assertEq(appointments.completedVisits(patient, doctor), 1);
    }

    function test_Complete_ProviderOnly() public {
        vm.prank(patient);
        vm.expectRevert(abi.encodeWithSelector(ShifaAppointments.NotProvider.selector, appointmentId));
        appointments.complete(appointmentId);
    }

    function test_Cancel_InTime_RefundsPatient() public {
        uint256 before = sar.balanceOf(patient);
        vm.prank(patient);
        appointments.cancel(appointmentId);
        assertEq(sar.balanceOf(patient), before + 500 ether);
        ( , , , , ShifaAppointments.Status status, ) = appointments.appointments(appointmentId);
        assertEq(uint8(status), uint8(ShifaAppointments.Status.Canceled));
    }

    function test_Cancel_Late_PaysProvider() public {
        vm.warp(block.timestamp + 2 days); // inside the 1-day window
        vm.prank(patient);
        appointments.cancel(appointmentId);
        assertEq(sar.balanceOf(doctor), 490 ether);
    }

    function test_NoShow_PaysProvider() public {
        vm.warp(block.timestamp + 3 days);
        vm.prank(doctor);
        appointments.markNoShow(appointmentId);
        ( , , , , ShifaAppointments.Status status, ) = appointments.appointments(appointmentId);
        assertEq(uint8(status), uint8(ShifaAppointments.Status.NoShow));
        assertEq(sar.balanceOf(doctor), 490 ether);
    }

    function test_DoubleComplete_Reverts() public {
        _completeVisit();
        vm.prank(doctor);
        vm.expectRevert(abi.encodeWithSelector(ShifaAppointments.InvalidStatus.selector, appointmentId, ShifaAppointments.Status.Booked, ShifaAppointments.Status.Completed));
        appointments.complete(appointmentId);
    }
}

contract ShifaInsuranceTest is ShifaFixture {
    function test_Subscribe_ChargesPremium() public {
        uint256 before = sar.balanceOf(patient);
        uint256 planId = _openInsurance();
        // 10,000 × 5% × 365/365 = 500
        assertEq(before - sar.balanceOf(patient), 500 ether);
        assertEq(insurance.planOf(patient), planId);
        assertEq(insurance.planCoverLeft(planId), 10_000 ether);
    }

    function test_Subscribe_NonInsurer_Reverts() public {
        vm.prank(patient);
        vm.expectRevert(ShifaInsurance.NotInsurer.selector);
        insurance.subscribe(doctor, 10_000 ether, 0, 365);
    }

    function test_PreAuthorize_InsurerOnly() public {
        _openInsurance();
        vm.prank(doctor);
        vm.expectRevert(ShifaInsurance.NotInsurer.selector);
        insurance.preAuthorize(0, doctor, bytes32("consult"), 1_000 ether, 30);
        vm.prank(insurer);
        uint256 preAuthId = insurance.preAuthorize(0, doctor, bytes32("consult"), 1_000 ether, 30);
        ( , address provider, bytes32 serviceHash, uint256 maxAmount, , bool used) = insurance.preAuths(preAuthId);
        assertEq(provider, doctor);
        assertEq(serviceHash, bytes32("consult"));
        assertEq(maxAmount, 1_000 ether);
        assertFalse(used);
    }

    function test_Claim_ApprovedByTwoReviewers_SplitsCopay() public {
        _approvedClaim();
        // 1,000 claim, 20% copay: insurer pays 800, patient owes 200
        ( , , uint256 amount, uint256 insurerShare, uint256 patientShare, , , , , bool paid) = insurance.claims(0);
        assertEq(amount, 1_000 ether);
        assertEq(insurerShare, 800 ether);
        assertEq(patientShare, 200 ether);
        assertTrue(paid);
        assertEq(sar.balanceOf(doctor), 800 ether); // the insurer's share reached the doctor
    }

    function test_Claim_DoubleVote_Reverts() public {
        _openInsurance();
        vm.prank(insurer);
        uint256 preAuthId = insurance.preAuthorize(0, doctor, bytes32("consult"), 1_000 ether, 30);
        vm.prank(doctor);
        uint256 id = insurance.fileClaim(preAuthId, 1_000 ether);
        vm.prank(reviewer1);
        insurance.voteClaim(id, true);
        vm.prank(reviewer1);
        vm.expectRevert(abi.encodeWithSelector(ShifaInsurance.AlreadyVoted.selector, id, reviewer1));
        insurance.voteClaim(id, true);
    }

    function test_Claim_TwoRejections_Rejected() public {
        _openInsurance();
        vm.prank(insurer);
        uint256 preAuthId = insurance.preAuthorize(0, doctor, bytes32("consult"), 1_000 ether, 30);
        vm.prank(doctor);
        uint256 id = insurance.fileClaim(preAuthId, 1_000 ether);
        vm.prank(reviewer1);
        insurance.voteClaim(id, false);
        vm.prank(reviewer2);
        insurance.voteClaim(id, false);
        ( , , , , , , , bool decided, bool approved, bool paid) = insurance.claims(id);
        assertTrue(decided);
        assertFalse(approved);
        assertFalse(paid);
    }

    function test_Claim_CappedByCoverage() public {
        vm.prank(patient);
        insurance.subscribe(insurer, 1_000 ether, 2000, 365);
        vm.prank(insurer);
        uint256 preAuthId = insurance.preAuthorize(0, doctor, bytes32("surgery"), 5_000 ether, 30);
        vm.prank(doctor);
        uint256 id = insurance.fileClaim(preAuthId, 5_000 ether);
        vm.prank(reviewer1);
        insurance.voteClaim(id, true);
        vm.prank(reviewer2);
        insurance.voteClaim(id, true);
        ( , , , uint256 insurerShare, uint256 patientShare, , , , , ) = insurance.claims(id);
        // capped at the 1,000 limit: insurer 800, patient 200
        assertEq(insurerShare, 800 ether);
        assertEq(patientShare, 200 ether);
        assertEq(insurance.planCoverLeft(0), 0);
    }

    function test_Claim_AbovePreAuth_Reverts() public {
        _openInsurance();
        vm.prank(insurer);
        uint256 preAuthId = insurance.preAuthorize(0, doctor, bytes32("consult"), 1_000 ether, 30);
        vm.prank(doctor);
        vm.expectRevert(ShifaInsurance.ZeroAmount.selector);
        insurance.fileClaim(preAuthId, 2_000 ether);
    }

    function test_Claim_ExpiredPreAuth_Reverts() public {
        _openInsurance();
        vm.prank(insurer);
        uint256 preAuthId = insurance.preAuthorize(0, doctor, bytes32("consult"), 1_000 ether, 10);
        vm.warp(block.timestamp + 11 days);
        vm.prank(doctor);
        vm.expectRevert(abi.encodeWithSelector(ShifaInsurance.PreAuthExpired.selector, preAuthId));
        insurance.fileClaim(preAuthId, 1_000 ether);
    }

    function test_Claim_ProviderOnly() public {
        _openInsurance();
        vm.prank(insurer);
        uint256 preAuthId = insurance.preAuthorize(0, doctor, bytes32("consult"), 1_000 ether, 30);
        vm.prank(patient);
        vm.expectRevert(ShifaInsurance.NotProvider.selector);
        insurance.fileClaim(preAuthId, 1_000 ether);
    }
}

contract ShifaPaymentsTest is ShifaFixture {
    function test_PayForService_TakesFee() public {
        uint256 providerBefore = sar.balanceOf(doctor);
        vm.prank(patient);
        uint256 id = payments.payForService(doctor, 1_000 ether, bytes32("checkup"));
        // 1,000 − 1.5% = 985 to the doctor
        assertEq(sar.balanceOf(doctor) - providerBefore, 985 ether);
        assertEq(payments.earnings(doctor), 985 ether);
        ( , , uint256 amount, uint256 fee, , , bool insured, ) = payments.receipts(id);
        assertEq(amount, 1_000 ether);
        assertEq(fee, 15 ether);
        assertFalse(insured);
    }

    function test_PayCopay_AfterApprovedClaim() public {
        _approvedClaim();
        uint256 providerBefore = sar.balanceOf(doctor);
        vm.prank(patient);
        uint256 id = payments.payCopay(0, bytes32("copay"));
        // 200 patient share − 0.5% = 199 to the doctor
        assertEq(sar.balanceOf(doctor) - providerBefore, 199 ether);
        ( , , , uint256 fee, , uint256 claimId, bool insured, ) = payments.receipts(id);
        assertEq(claimId, 0);
        assertTrue(insured);
        assertEq(fee, 1 ether);
    }

    function test_PayCopay_Unapproved_Reverts() public {
        _openInsurance();
        vm.prank(insurer);
        uint256 preAuthId = insurance.preAuthorize(0, doctor, bytes32("consult"), 1_000 ether, 30);
        vm.prank(doctor);
        insurance.fileClaim(preAuthId, 1_000 ether);
        // not voted yet: the claim is not paid
        vm.prank(patient);
        vm.expectRevert(abi.encodeWithSelector(ShifaPayments.ClaimNotApproved.selector, 0));
        payments.payCopay(0, bytes32("copay"));
    }

    function test_Fee_SplitToTreasury() public {
        vm.prank(patient);
        payments.payForService(doctor, 1_000 ether, bytes32("checkup"));
        assertEq(sar.balanceOf(address(treasury)), 15 ether);
    }

    function test_SetFees_GovernanceOnly() public {
        vm.prank(patient);
        vm.expectRevert();
        payments.setFees(500, 500);
        vm.prank(address(governor));
        payments.setFees(300, 100);
        assertEq(payments.feeBps(), 300);
    }
}

contract ShifaReputationTest is ShifaFixture {
    function test_NeutralScore_WithoutRatings() public {
        assertEq(reputation.scoreOf(doctor), 500);
    }

    function test_Rate_RequiresCompletedVisit() public {
        vm.prank(patient);
        vm.expectRevert(abi.encodeWithSelector(ShifaReputation.NotPatientOfVisit.selector, patient, doctor));
        reputation.rate(appointmentId, 90);
    }

    function test_Rate_AfterCompletion_LiftsScore() public {
        _completeVisit();
        vm.prank(patient);
        reputation.rate(appointmentId, 100);
        assertEq(reputation.ratingCount(doctor), 1);
        // one perfect rating: score = (1000×100 + 500×9900)/10000 = 505
        assertEq(reputation.scoreOf(doctor), 505);
    }

    function test_Rate_Twice_Reverts() public {
        _completeVisit();
        vm.prank(patient);
        reputation.rate(appointmentId, 80);
        vm.prank(patient);
        vm.expectRevert(abi.encodeWithSelector(ShifaReputation.AlreadyRated.selector, appointmentId));
        reputation.rate(appointmentId, 90);
    }

    function test_Rate_InvalidScore_Reverts() public {
        _completeVisit();
        vm.prank(patient);
        vm.expectRevert(abi.encodeWithSelector(ShifaReputation.InvalidScore.selector, uint8(101)));
        reputation.rate(appointmentId, 101);
    }

    function test_Checkpoint_RecordsHistory() public {
        _completeVisit();
        vm.prank(patient);
        reputation.rate(appointmentId, 100);
        reputation.checkpoint(doctor);
        assertEq(reputation.getPastScore(doctor, block.number), 505);
    }

    function test_Decay_PullsTowardNeutral() public {
        _completeVisit();
        vm.prank(patient);
        reputation.rate(appointmentId, 100);
        reputation.checkpoint(doctor);
        vm.warp(block.timestamp + 30 days);
        // score drifts back toward 500
        assertLt(reputation.scoreOf(doctor), 505);
        assertGt(reputation.scoreOf(doctor), 500);
    }
}

contract ShifaTreasuryTest is ShifaFixture {
    function test_ReceiveFees_And_Pay() public {
        _completeVisit();
        assertEq(sar.balanceOf(address(treasury)), 10 ether);
        vm.prank(address(governor));
        treasury.grantRole(treasury.OPERATOR_ROLE(), address(this));
        treasury.pay(outsider, 1 ether);
        assertEq(sar.balanceOf(outsider), 1 ether);
    }

    function test_ReserveFloor_BlocksPayment() public {
        _completeVisit();
        vm.prank(address(governor));
        treasury.grantRole(treasury.OPERATOR_ROLE(), address(this));
        // 20% of 10 = 2 must stay behind
        vm.expectRevert(abi.encodeWithSelector(ShifaTreasury.ReserveBreach.selector, uint256(0), uint256(2 ether)));
        treasury.pay(outsider, 10 ether);
    }

    function test_Drain_GuardianOnly() public {
        _completeVisit();
        vm.prank(outsider);
        vm.expectRevert();
        treasury.drain(outsider);
        vm.prank(guardian);
        treasury.drain(guardian);
        assertEq(sar.balanceOf(guardian), 10 ether);
    }
}

contract ShifaGovernorTest is ShifaFixture {
    function _checkpointVoter(address voter) internal {
        reputation.checkpoint(voter);
    }

    function test_Propose_RejectsUnknownTarget() public {
        vm.expectRevert(ShifaGovernor.InvalidTargets.selector);
        governor.propose(outsider, 0, hex"1234", "attack");
    }

    function test_Propose_StoresDetails() public {
        bytes memory data = abi.encodeCall(ShifaAppointments.setFee, (300));
        uint256 id = governor.propose(address(appointments), 0, data, "raise visit fee to 3%");
        (address proposer, , uint256 voteStart, , , , , , , address target, , , string memory description) = governor.proposals(id);
        assertEq(proposer, address(this));
        assertEq(target, address(appointments));
        assertGt(voteStart, block.timestamp);
        assertEq(description, "raise visit fee to 3%");
        assertEq(governor.state(id), 0); // review
    }

    function test_FullLifecycle_ChangesFee() public {
        _checkpointVoter(patient);
        bytes memory data = abi.encodeCall(ShifaAppointments.setFee, (300));
        uint256 id = governor.propose(address(appointments), 0, data, "raise visit fee to 3%");

        vm.warp(block.timestamp + 2 days + 1);
        assertEq(governor.state(id), 1); // voting
        vm.prank(patient);
        governor.vote(id, true);
        ( , , , , , uint256 forVotes, , , , , , , ) = governor.proposals(id);
        assertEq(forVotes, 500);

        vm.warp(block.timestamp + 5 days + 2 days + 1);
        assertEq(governor.state(id), 3); // succeeded
        governor.execute(id);
        assertEq(governor.state(id), 4); // executed
        assertEq(appointments.feeBps(), 300);
    }

    function test_Timelock_BlocksEarlyExecution() public {
        _checkpointVoter(patient);
        bytes memory data = abi.encodeCall(ShifaAppointments.setFee, (300));
        uint256 id = governor.propose(address(appointments), 0, data, "fee");
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(patient);
        governor.vote(id, true);
        vm.warp(block.timestamp + 5 days + 1); // voting over, timelock running
        assertEq(governor.state(id), 2);
        vm.expectRevert();
        governor.execute(id);
    }

    function test_Defeated_WhenQuorumMissed() public {
        bytes memory data = abi.encodeCall(ShifaAppointments.setFee, (300));
        uint256 id = governor.propose(address(appointments), 0, data, "no votes");
        vm.warp(block.timestamp + 2 days + 5 days + 3 days + 1);
        assertEq(governor.state(id), 5); // defeated
    }

    function test_Vote_OutsideWindow_Reverts() public {
        _checkpointVoter(patient);
        bytes memory data = abi.encodeCall(ShifaAppointments.setFee, (300));
        uint256 id = governor.propose(address(appointments), 0, data, "fee");
        vm.prank(patient);
        vm.expectRevert(abi.encodeWithSelector(ShifaGovernor.NotInVoting.selector, id));
        governor.vote(id, true);
    }

    function test_DoubleVote_Reverts() public {
        _checkpointVoter(patient);
        bytes memory data = abi.encodeCall(ShifaAppointments.setFee, (300));
        uint256 id = governor.propose(address(appointments), 0, data, "fee");
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(patient);
        governor.vote(id, true);
        vm.prank(patient);
        vm.expectRevert(abi.encodeWithSelector(ShifaGovernor.AlreadyVoted.selector, id, patient));
        governor.vote(id, true);
    }

    function test_Cancel_ByProposer() public {
        bytes memory data = abi.encodeCall(ShifaAppointments.setFee, (300));
        uint256 id = governor.propose(address(appointments), 0, data, "fee");
        governor.cancel(id);
        assertEq(governor.state(id), 6);
    }

    function test_Pause_GuardianOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        governor.pause();
        vm.prank(guardian);
        governor.pause();
        vm.expectRevert(ShifaGovernor.ProtocolPaused.selector);
        governor.propose(address(appointments), 0, hex"1234", "paused");
    }
}
