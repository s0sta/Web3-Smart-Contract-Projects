// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title MerkleProof
/// @notice From-scratch Merkle proof verification (same algorithm as OpenZeppelin's library).
/// @dev Leaves are hashed with keccak256; pairs are sorted before hashing so proofs are
///      order-independent. Used for gas-efficient whitelists and airdrops.
library MerkleProof {
    /// @notice Returns true if `leaf` can be proven to be part of the tree with `root`.
    function verify(bytes32[] calldata proof, bytes32 root, bytes32 leaf) internal pure returns (bool) {
        bytes32 computedHash = leaf;
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 proofElement = proof[i];
            if (computedHash <= proofElement) {
                computedHash = keccak256(abi.encodePacked(computedHash, proofElement));
            } else {
                computedHash = keccak256(abi.encodePacked(proofElement, computedHash));
            }
        }
        return computedHash == root;
    }
}
