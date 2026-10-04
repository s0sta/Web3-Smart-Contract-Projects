// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
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

/// @notice The complete identity stack: the DID registry, the schema registry
///         (an "IdentityCard" schema with name/dob/nationality), the treasury,
///         the credential ledger (5 AED-S issuance fee), the attestation desk,
///         the reputation engine, the access gates, social recovery and the
///         reputation-weighted governor.
abstract contract HuwiyyaFixture is Test {
    MockStable internal feeToken;
    HuwiyyaRegistry internal registry;
    HuwiyyaSchema internal schemas;
    HuwiyyaTreasury internal treasury;
    HuwiyyaCredentials internal credentials;
    HuwiyyaAttestations internal attestations;
    HuwiyyaReputation internal reputation;
    HuwiyyaGates internal gates;
    HuwiyyaRecovery internal recovery;
    HuwiyyaGovernor internal governor;

    address internal issuer = address(0x1);
    address internal officer = address(0xC);
    address internal guardian = address(0x6);
    address internal holder = address(0xA);
    address internal verifier = address(0xB);
    address internal attestor = address(0xD);
    address internal guardian1 = address(0xE1);
    address internal guardian2 = address(0xE2);
    address internal outsider = address(0x99);

    uint256 internal schemaId;
    uint256 internal credentialId;
    uint256 internal policyId;

    bytes32 internal claimName;
    bytes32 internal claimDob;
    bytes32 internal claimNationality;
    bytes32 internal claimsRoot;
    bytes32[] internal dobProof;

    function setUp() public virtual {
        feeToken = new MockStable();
        registry = new HuwiyyaRegistry();
        schemas = new HuwiyyaSchema();
        treasury = new HuwiyyaTreasury(feeToken, 2000);
        credentials = new HuwiyyaCredentials(registry, schemas, treasury, feeToken);
        attestations = new HuwiyyaAttestations(registry);
        reputation = new HuwiyyaReputation(attestations);
        gates = new HuwiyyaGates(registry, credentials, reputation);
        recovery = new HuwiyyaRecovery(registry);
        governor = new HuwiyyaGovernor(reputation, registry, credentials, attestations, gates, recovery, treasury, schemas, 300);

        // wiring
        registry.grantRole(registry.RECOVERY_ROLE(), address(recovery));
        registry.grantRole(registry.OFFICER_ROLE(), officer);
        credentials.grantRole(credentials.ISSUER_ROLE(), issuer);
        attestations.grantRole(attestations.ATTESTOR_ROLE(), attestor);
        credentials.grantRole(credentials.DEFAULT_ADMIN_ROLE(), address(governor));
        attestations.setWeight(attestor, 10_000);
        governor.grantRole(governor.GUARDIAN_ROLE(), guardian);

        // schema: IdentityCard (name, dob, nationality)
        string[] memory names = new string[](3);
        names[0] = "name";
        names[1] = "dob";
        names[2] = "nationality";
        HuwiyyaSchema.FieldType[] memory types = new HuwiyyaSchema.FieldType[](3);
        types[0] = HuwiyyaSchema.FieldType.String;
        types[1] = HuwiyyaSchema.FieldType.Date;
        types[2] = HuwiyyaSchema.FieldType.String;
        schemaId = schemas.publishSchema("IdentityCard", 1, names, types);

        // the holder's DID
        vm.prank(holder);
        registry.createDid(bytes32("doc"));

        // claims (hashed leaves) + the Merkle root
        claimName = keccak256(abi.encode("Ali"));
        claimDob = keccak256(abi.encode(uint256(1990)));
        claimNationality = keccak256(abi.encode("UAE"));
        bytes32[] memory leaves = new bytes32[](3);
        leaves[0] = claimName;
        leaves[1] = claimDob;
        leaves[2] = claimNationality;

        claimsRoot = _commit(leaves);
        // proof for dob (index 1) in the padded 4-leaf tree:
        // root = H(H(name, dob), H(nationality, 0))
        dobProof = new bytes32[](2);
        dobProof[0] = claimName; // sibling at the first level
        dobProof[1] = HuwiyyaMerkleLib.hashPair(claimNationality, bytes32(0)); // sibling at the second level

        // the issuer issues the credential to the holder
        feeToken.setMinter(address(this));
        feeToken.mint(issuer, 1_000 ether);
        vm.prank(issuer);
        feeToken.approve(address(credentials), 1_000 ether);
        vm.prank(issuer);
        credentialId = credentials.issue(holder, schemaId, claimsRoot, 0, true);

        // an access policy: IdentityCard + 600 reputation + dob ≥ 1990
        uint256[] memory req = new uint256[](1);
        req[0] = schemaId;
        policyId = gates.createPolicy(req, 600, 1, 1990);

        // attestation → reputation 800 → "Verified" band
        vm.prank(attestor);
        attestations.submit(holder, 1, 800, 0, bytes32("kyc-evidence"));
        reputation.checkpoint(holder);
    }

    function _commit(bytes32[] memory leaves) internal pure returns (bytes32) {
        return HuwiyyaMerkleLib.commit(leaves);
    }

}

library HuwiyyaMerkleLib {
    function hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(a < b ? a : b, a < b ? b : a));
    }

    function commit(bytes32[] memory leaves) internal pure returns (bytes32) {
        uint256 n = leaves.length;
        uint256 size = 1;
        while (size < n) size <<= 1;
        bytes32[] memory layer = new bytes32[](size);
        for (uint256 i = 0; i < n; i++) layer[i] = leaves[i];
        while (size > 1) {
            uint256 half = size / 2;
            for (uint256 i = 0; i < half; i++) {
                layer[i] = hashPair(layer[2 * i], layer[2 * i + 1]);
            }
            size = half;
        }
        return layer[0];
    }
}
