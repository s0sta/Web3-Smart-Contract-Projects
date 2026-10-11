// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Checkpoints
/// @notice Gas-efficient, snapshot-capable checkpoint history — the data structure that
///         makes "voting power at block N" queries O(log n) instead of O(n).
/// @dev Votes are stored in descending-block order as {fromBlock, votes} pairs, one entry
///      per power change (multiple changes in the same block collapse into one entry).
///      Binary search recovers the exact power at any past block — the same pattern used
///      by OpenZeppelin's `Votes`, reimplemented from scratch and documented here.
library Checkpoints {
    /// @notice A single power snapshot, effective from `fromBlock` onwards.
    /// @dev `votes` is 224 bits: 32 + 224 = 256, one storage slot per checkpoint.
    struct Checkpoint {
        uint32 fromBlock;
        uint224 votes;
    }

    /// @notice Thrown when a snapshot at a future block is requested.
    error FutureBlock(uint256 requested, uint256 current);

    /// @notice Thrown when a vote count exceeds the 224-bit slot width.
    error VotesOverflow(uint256 votes);

    /// @notice Thrown when binary-search bounds become inconsistent (should never happen).
    error InvalidBounds();

    /// @notice Records a new power value for the current block.
    /// @param cps The checkpoint history to extend.
    /// @param oldVotes The previous power (unused by storage — kept for interface clarity).
    /// @param newVotes The new power value.
    /// @dev If the latest checkpoint is from the current block, it is overwritten instead
    ///      of appended, keeping the history minimal.
    function write(
        Checkpoint[] storage cps,
        uint256 oldVotes,
        uint256 newVotes
    ) internal returns (uint256) {
        if (newVotes > type(uint224).max) revert VotesOverflow(newVotes);
        uint32 blockNumber = _safe32(block.number);
        uint256 length = cps.length;
        if (length > 0 && cps[length - 1].fromBlock == blockNumber) {
            cps[length - 1].votes = uint224(newVotes);
        } else {
            cps.push(Checkpoint({ fromBlock: blockNumber, votes: uint224(newVotes) }));
        }
        return newVotes;
    }

    /// @notice Appends a checkpoint without overwriting the current-block entry.
    /// @dev Useful when a single transaction performs several power moves that must each
    ///      remain queryable by their intermediate values at the same block number.
    function push(Checkpoint[] storage cps, uint256 newVotes) internal {
        if (newVotes > type(uint224).max) revert VotesOverflow(newVotes);
        cps.push(Checkpoint({ fromBlock: _safe32(block.number), votes: uint224(newVotes) }));
    }

    /// @notice The most recent recorded power.
    function latest(Checkpoint[] storage cps) internal view returns (uint256) {
        uint256 length = cps.length;
        return length == 0 ? 0 : cps[length - 1].votes;
    }

    /// @notice The power recorded at or before `blockNumber`.
    /// @dev Binary search over the descending-block list: O(log n).
    function lookup(Checkpoint[] storage cps, uint256 blockNumber) internal view returns (uint256) {
        uint256 length = cps.length;
        if (length == 0) return 0;

        // Fast paths: newest and oldest entries.
        if (blockNumber >= cps[length - 1].fromBlock) return cps[length - 1].votes;
        if (blockNumber < cps[0].fromBlock) return 0;

        // Invariant: cps[low].fromBlock <= blockNumber < cps[high].fromBlock
        uint256 low = 0;
        uint256 high = length - 1;
        while (high - low > 1) {
            uint256 mid = (low + high) / 2;
            if (cps[mid].fromBlock > blockNumber) {
                high = mid;
            } else {
                low = mid;
            }
        }
        return cps[low].votes;
    }

    /// @notice Returns the block of the latest checkpoint (0 when empty).
    function latestBlock(Checkpoint[] storage cps) internal view returns (uint32) {
        uint256 length = cps.length;
        return length == 0 ? 0 : cps[length - 1].fromBlock;
    }

    /// @dev Fails loudly instead of silently truncating a block number.
    function _safe32(uint256 n) private pure returns (uint32) {
        if (n > type(uint32).max) revert FutureBlock(n, type(uint32).max);
        return uint32(n);
    }
}
