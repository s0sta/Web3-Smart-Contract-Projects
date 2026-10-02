// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title GovToken
/// @notice A governance ERC-20 with historical voting-power snapshots, written from scratch
///         (OpenZeppelin "Votes"-style checkpoints). Any block in the past can be queried for
///         an account's balance — this is what makes flash-loan vote buying impossible.
contract GovToken {
    /// @notice One snapshot of an account's voting power at a block number.
    struct Checkpoint {
        uint32 fromBlock;
        uint224 votes;
    }

    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    /// @notice Per-account checkpoint history (appended, never mutated backwards).
    mapping(address => Checkpoint[]) private _userCheckpoints;

    /// @notice Total-supply checkpoint history.
    Checkpoint[] private _totalCheckpoints;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error ZeroAddress();
    error InsufficientBalance(uint256 balance, uint256 amount);
    error InsufficientAllowance(uint256 allowed, uint256 amount);
    error FutureBlock(uint256 requested, uint256 current);

    /// @param name_ / @param symbol_ Token metadata.
    /// @param initialSupply Full initial supply (no further minting — supply is fixed).
    /// @param to Recipient of the initial supply (the deployer distributes from here).
    constructor(string memory name_, string memory symbol_, uint256 initialSupply, address to) {
        if (to == address(0)) revert ZeroAddress();
        name = name_;
        symbol = symbol_;
        totalSupply = initialSupply;
        balanceOf[to] = initialSupply;
        _writeUserCheckpoint(to, 0, initialSupply);
        _writeTotalCheckpoint(0, initialSupply);
        emit Transfer(address(0), to, initialSupply);
    }

    /* ==================== ERC-20 CORE ==================== */

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance(allowed, amount);
            allowance[from][msg.sender] = allowed - amount;
        }
        _move(from, to, amount);
        return true;
    }

    /* ==================== SNAPSHOTS ==================== */

    /// @notice An account's voting power at the end of `blockNumber`.
    /// @dev BlockNumber may equal the current block (reads the latest checkpoint). The
    ///      governor snapshots at proposal creation, and transfers in LATER blocks don't
    ///      change that snapshot — see the flash-vote-buying test.
    function getPastVotes(address account, uint256 blockNumber) public view returns (uint256) {
        if (blockNumber > block.number) revert FutureBlock(blockNumber, block.number);
        return _lookup(_userCheckpoints[account], blockNumber);
    }

    /// @notice Total voting power at the end of `blockNumber`.
    function getPastTotalSupply(uint256 blockNumber) public view returns (uint256) {
        if (blockNumber > block.number) revert FutureBlock(blockNumber, block.number);
        return _lookup(_totalCheckpoints, blockNumber);
    }

    /// @notice Number of checkpoints recorded for `account` (diagnostics).
    function numCheckpoints(address account) public view returns (uint256) {
        return _userCheckpoints[account].length;
    }

    /* ==================== INTERNALS ==================== */

    function _move(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < amount) revert InsufficientBalance(fromBalance, amount);

        balanceOf[from] = fromBalance - amount;
        balanceOf[to] += amount;
        _writeUserCheckpoint(from, fromBalance, balanceOf[from]);
        _writeUserCheckpoint(to, balanceOf[to] - amount, balanceOf[to]);
        emit Transfer(from, to, amount);
    }

    function _writeUserCheckpoint(address account, uint256 oldBalance, uint256 newBalance) internal {
        Checkpoint[] storage cps = _userCheckpoints[account];
        uint256 len = cps.length;
        if (len > 0 && cps[len - 1].fromBlock == block.number) {
            cps[len - 1].votes = uint224(newBalance);
        } else {
            cps.push(Checkpoint(uint32(block.number), uint224(newBalance)));
        }
    }

    function _writeTotalCheckpoint(uint256 oldTotal, uint256 newTotal) internal {
        uint256 len = _totalCheckpoints.length;
        if (len > 0 && _totalCheckpoints[len - 1].fromBlock == block.number) {
            _totalCheckpoints[len - 1].votes = uint224(newTotal);
        } else {
            _totalCheckpoints.push(Checkpoint(uint32(block.number), uint224(newTotal)));
        }
    }

    /// @dev Binary search: last checkpoint with fromBlock <= target (returns 0 if none).
    function _lookup(Checkpoint[] storage cps, uint256 targetBlock) internal view returns (uint256) {
        uint256 len = cps.length;
        if (len == 0) return 0;
        if (cps[0].fromBlock > targetBlock) return 0;
        if (cps[len - 1].fromBlock <= targetBlock) return cps[len - 1].votes;
        uint256 low = 0;
        uint256 high = len - 1;
        while (low < high) {
            uint256 mid = (low + high + 1) / 2;
            if (cps[mid].fromBlock <= targetBlock) {
                low = mid;
            } else {
                high = mid - 1;
            }
        }
        return cps[low].votes;
    }
}
