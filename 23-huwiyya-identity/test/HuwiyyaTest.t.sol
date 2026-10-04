// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {HuwiyyaFixture, HuwiyyaMerkleLib} from "./HuwiyyaFixture.sol";
import {HuwiyyaRegistry} from "../src/HuwiyyaRegistry.sol";
import {HuwiyyaSchema} from "../src/HuwiyyaSchema.sol";
import {HuwiyyaCredentials} from "../src/HuwiyyaCredentials.sol";
import {HuwiyyaAttestations} from "../src/HuwiyyaAttestations.sol";
import {HuwiyyaReputation} from "../src/HuwiyyaReputation.sol";
import {HuwiyyaGates} from "../src/HuwiyyaGates.sol";
import {HuwiyyaRecovery} from "../src/HuwiyyaRecovery.sol";
import {HuwiyyaTreasury} from "../src/HuwiyyaTreasury.sol";
import {HuwiyyaGovernor} from "../src/HuwiyyaGovernor.sol";

contract HuwiyyaRegistryTest is HuwiyyaFixture {
    function test_CreateDid() public {
        assertEq(registry.didCount(), 1);
        (address key, , , , bool frozen, bool revoked) = registry.dids(holder);
        assertEq(key, holder);
        assertFalse(frozen);
        assertFalse(revoked);
    }

    function test_RotateKey_ControllerOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        registry.rotateKey(outsider);
        vm.prank(holder);
        registry.rotateKey(verifier);
        (address key, , , , , ) = registry.dids(holder);
        assertEq(key, verifier);
    }

    function test_Freeze_OfficerOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        registry.setFrozen(holder, true);
        vm.prank(officer);
        registry.setFrozen(holder, true);
        assertFalse(registry.isActive(holder));
        vm.prank(holder);
        vm.expectRevert();
        registry.updateDoc(bytes32("blocked"));
    }

    function test_Revoke_Self() public {
        vm.prank(holder);
        registry.revokeDid(holder);
        ( , , , , , bool revoked) = registry.dids(holder);
        assertTrue(revoked);
    }
}

contract HuwiyyaSchemaTest is HuwiyyaFixture {
    function test_PublishAndRead() public {
        (string memory name, uint64 version, bool active) = schemas.schemas(schemaId);
        assertEq(name, "IdentityCard");
        assertEq(version, 1);
        assertTrue(active);
        HuwiyyaSchema.Field memory f = schemas.field(schemaId, 1);
        assertEq(f.name, "dob");
    }

    function test_Publish_OperatorOnly() public {
        string[] memory names = new string[](1);
        names[0] = "x";
        HuwiyyaSchema.FieldType[] memory types = new HuwiyyaSchema.FieldType[](1);
        types[0] = HuwiyyaSchema.FieldType.String;
        vm.prank(outsider);
        vm.expectRevert();
        schemas.publishSchema("X", 1, names, types);
    }
}

contract HuwiyyaCredentialsTest is HuwiyyaFixture {
    function test_Issue_RecordsAndChargesFee() public {
        (address iss, address sub, uint256 s, bytes32 root, , , , ) = credentials.credentials(credentialId);
        assertEq(iss, issuer);
        assertEq(sub, holder);
        assertEq(s, schemaId);
        assertEq(root, claimsRoot);
        assertEq(treasury.totalFeesCollected(), 5 ether);
    }

    function test_Present_ValidProof() public {
        vm.prank(holder);
        bool ok = credentials.present(credentialId, verifier, 1, claimDob, dobProof);
        assertTrue(ok);
    }

    function test_Present_InvalidProof() public {
        vm.prank(holder);
        bool ok = credentials.present(credentialId, verifier, 1, claimName, dobProof); // wrong leaf
        assertFalse(ok);
    }

    function test_Present_OnlySubject() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(HuwiyyaCredentials.NotIssuerOrSubject.selector, credentialId));
        credentials.present(credentialId, verifier, 1, claimDob, dobProof);
    }

    function test_Revoke_Invalidates() public {
        vm.prank(issuer);
        credentials.revoke(credentialId);
        assertFalse(credentials.isValid(credentialId));
    }

    function test_Revoke_NonRevocable() public {
        vm.prank(verifier);
        registry.createDid(bytes32("v"));
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = bytes32("one");
        vm.prank(issuer);
        uint256 id = credentials.issue(verifier, schemaId, HuwiyyaMerkleLib.commit(leaves), 0, false);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(HuwiyyaCredentials.AlreadyRevoked.selector, id));
        credentials.revoke(id);
    }

    function test_Expiry_Invalidates() public {
        vm.prank(verifier);
        registry.createDid(bytes32("v"));
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = bytes32("one");
        vm.prank(issuer);
        uint256 id = credentials.issue(verifier, schemaId, HuwiyyaMerkleLib.commit(leaves), uint64(block.timestamp + 7 days), true);
        vm.warp(block.timestamp + 8 days);
        assertFalse(credentials.isValid(id));
    }
}

contract HuwiyyaAttestationsTest is HuwiyyaFixture {
    function test_Submit_AttestorOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        attestations.submit(holder, 1, 500, 0, bytes32("x"));
    }

    function test_Revoke_ZeroesScore() public {
        uint256 id = attestations.attestationsOfList(holder)[0];
        vm.prank(attestor);
        attestations.revoke(id);
        assertEq(attestations.activeScore(id), 0);
        assertEq(reputation.scoreOf(holder), 0);
    }
}

contract HuwiyyaReputationTest is HuwiyyaFixture {
    function test_ScoreFromAttestation() public {
        // one KYC attestation: 800 × 4000/10000 × 10000/10000 = 320
        assertEq(reputation.scoreOf(holder), 320);
        assertEq(reputation.bandOf(320), "New");
    }

    function test_HighScore_Band() public {
        vm.prank(attestor);
        attestations.submit(holder, 1, 1000, 0, bytes32("x"));
        vm.prank(attestor);
        attestations.submit(holder, 2, 1000, 0, bytes32("y"));
        uint256 score = reputation.scoreOf(holder);
        assertTrue(score > 0);
    }

    function test_Checkpoint_Snapshot() public {
        vm.roll(block.number + 1);
        reputation.checkpoint(holder);
        assertEq(reputation.getPastScore(holder, block.number), reputation.scoreOf(holder));
    }

    function test_Expired_AttestationDoesNotCount() public {
        vm.prank(attestor);
        attestations.submit(holder, 2, 1000, uint64(block.timestamp + 7 days), bytes32("x"));
        vm.warp(block.timestamp + 8 days);
        assertEq(reputation.scoreOf(holder), 320);
    }
}

contract HuwiyyaGatesTest is HuwiyyaFixture {
    function test_Access_WithCredential() public {
        // only the credential requirement matters when minReputation is unmet?
        // policy: IdentityCard + 600 reputation + dob ≥ 1990
        assertFalse(gates.checkAccess(policyId, holder)); // reputation 320 < 600
        vm.prank(attestor);
        attestations.submit(holder, 1, 1000, 0, bytes32("y"));
        assertTrue(gates.checkAccess(policyId, holder));
    }

    function test_Access_ClaimCheck() public {
        vm.prank(attestor);
        attestations.submit(holder, 1, 1000, 0, bytes32("y"));
        assertFalse(gates.checkAccessWithClaim(policyId, holder, 1980)); // dob too young
        assertTrue(gates.checkAccessWithClaim(policyId, holder, 1990));
    }

    function test_Access_UnknownDid() public {
        assertFalse(gates.checkAccess(policyId, outsider));
    }
}

contract HuwiyyaRecoveryTest is HuwiyyaFixture {
    function _setupGuardians() internal {
        address[] memory gs = new address[](2);
        gs[0] = guardian1;
        gs[1] = guardian2;
        vm.prank(holder);
        recovery.setGuardians(gs);
    }

    function test_Recovery_TwoOfTwo() public {
        _setupGuardians();
        vm.prank(holder);
        uint256 id = recovery.initiate(verifier);
        vm.prank(guardian1);
        recovery.approve(id);
        vm.prank(guardian2);
        vm.expectRevert();
        recovery.approve(id); // still within the 1-day delay
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(guardian2);
        recovery.approve(id);
        (address key, , , , , ) = registry.dids(holder);
        assertEq(key, verifier);
    }

    function test_Approve_OnlyGuardian() public {
        _setupGuardians();
        vm.prank(holder);
        uint256 id = recovery.initiate(verifier);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(HuwiyyaRecovery.NotGuardian.selector, outsider, holder));
        recovery.approve(id);
    }

    function test_Guardian_DoubleApprove() public {
        _setupGuardians();
        vm.prank(holder);
        uint256 id = recovery.initiate(verifier);
        vm.prank(guardian1);
        recovery.approve(id);
        vm.prank(guardian1);
        vm.expectRevert(abi.encodeWithSelector(HuwiyyaRecovery.AlreadyApproved.selector, id, guardian1));
        recovery.approve(id);
    }
}

contract HuwiyyaGovernorTest is HuwiyyaFixture {
    function test_Propose_ReputationWeighted() public {
        vm.prank(holder);
        uint256 id = governor.propose(address(credentials), 0, abi.encodeCall(credentials.setIssuanceFee, (10 ether)), "raise issuance fee");
        vm.warp(block.timestamp + 3 days);
        vm.prank(holder);
        governor.vote(id, true);
        ( , , , , , uint256 forV, , , , , , , ) = governor.proposals(id);
        assertEq(forV, reputation.scoreOf(holder));
    }

    function test_FullLifecycle_ChangesFee() public {
        vm.prank(holder);
        uint256 id = governor.propose(address(credentials), 0, abi.encodeCall(credentials.setIssuanceFee, (10 ether)), "raise fee");
        vm.warp(block.timestamp + 3 days);
        vm.prank(holder);
        governor.vote(id, true);
        vm.warp(block.timestamp + 10 days);
        assertEq(governor.state(id), 3);
        governor.execute(id);
        assertEq(governor.state(id), 4);
        assertEq(credentials.issuanceFee(), 10 ether);
    }

    function test_InvalidTarget_Rejected() public {
        vm.expectRevert(HuwiyyaGovernor.InvalidTargets.selector);
        governor.propose(address(0xDEAD), 0, hex"1234", "escape");
    }

    function test_Timelock_BlocksEarly() public {
        vm.prank(holder);
        uint256 id = governor.propose(address(credentials), 0, abi.encodeCall(credentials.setIssuanceFee, (10 ether)), "timelocked");
        vm.warp(block.timestamp + 3 days);
        vm.prank(holder);
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
        vm.expectRevert(HuwiyyaGovernor.ProtocolPaused.selector);
        governor.propose(address(credentials), 0, hex"1234", "paused");
    }
}
