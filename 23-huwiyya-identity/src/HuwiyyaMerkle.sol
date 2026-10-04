// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title HuwiyyaMerkle
/// @notice From-scratch Merkle tree helpers for selective disclosure: a holder
///         commits to the root of their claims; a proof reveals one claim and
///         proves membership without exposing the others.
library HuwiyyaMerkle {
    error InvalidProof();

    /// @notice Hashes two nodes together (sorted pair).
    function hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(a < b ? a : b, a < b ? b : a));
    }

    /// @notice Computes the root of a claims list (padded to a power of two).
    function commit(bytes32[] memory leaves) internal pure returns (bytes32 root) {
        if (leaves.length == 0) return bytes32(0);
        uint256 n = leaves.length;
        // pad to the next power of two
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

    /// @notice Verifies that `leaf` sits at `index` under `root` with `proof`.
    function verify(bytes32 root, bytes32 leaf, uint256 index, bytes32[] memory proof) internal pure returns (bool) {
        bytes32 node = leaf;
        uint256 idx = index;
        for (uint256 i = 0; i < proof.length; i++) {
            if (idx % 2 == 0) {
                node = hashPair(node, proof[i]);
            } else {
                node = hashPair(proof[i], node);
            }
            idx /= 2;
        }
        return node == root;
    }
}
