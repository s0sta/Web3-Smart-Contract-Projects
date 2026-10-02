// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./IERC20.sol";
import {Ownable} from "./Ownable.sol";
import {ReentrancyGuard} from "./ReentrancyGuard.sol";

/// @title StakeVault
/// @notice A staking vault written from scratch (Synthetix `StakingRewards` architecture):
///         users stake an ERC-20 and earn a second ERC-20 at a fixed global rate per second,
///         pro-rated by their share of the pool. Fair by construction: every staker's rate
///         is checkpointed when they stake/withdraw/claim.
contract StakeVault is Ownable, ReentrancyGuard {
    /// @notice Token users stake.
    IERC20 public immutable stakingToken;

    /// @notice Token users earn.
    IERC20 public immutable rewardsToken;

    /// @notice Total staked tokens.
    uint256 public totalSupply;

    /// @notice Each user's staked balance.
    mapping(address => uint256) public balanceOf;

    /// @notice Last global reward-per-token value this user accounted for.
    mapping(address => uint256) public userRewardPerTokenPaid;

    /// @notice Claimable-but-unclaimed rewards per user.
    mapping(address => uint256) public rewards;

    /// @notice Current emission rate: reward tokens per second across the whole pool.
    uint256 public rewardRate;

    /// @notice Timestamp when the current emission period ends.
    uint256 public periodFinish;

    /// @notice Last time the global accumulator was updated.
    uint256 public lastUpdateTime;

    /// @notice Global accumulator: reward tokens per staked token, 1e18-scaled.
    uint256 public rewardPerTokenStored;

    uint256 private constant PRECISION = 1e18;

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);
    event RewardsNotified(uint256 amount, uint256 duration, uint256 rate);
    event EmergencyWithdrawn(address indexed user, uint256 amount);
    event Recovered(address indexed token, uint256 amount);

    error ZeroAmount();
    error InsufficientStake(uint256 balance, uint256 amount);
    error InvalidDuration();
    error TransferFailed();
    error ProtectedToken(address token);

    /// @dev Updates the global accumulator and (if `account != 0`) that user's checkpoint
    ///      before any balance-changing operation.
    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    /// @param stakingToken_ Token users stake.
    /// @param rewardsToken_ Token users earn.
    /// @param initialOwner Address allowed to fund emissions via `startRewards`.
    constructor(IERC20 stakingToken_, IERC20 rewardsToken_, address initialOwner) Ownable(initialOwner) {
        stakingToken = stakingToken_;
        rewardsToken = rewardsToken_;
    }

    /* ==================== REWARD MATH ==================== */

    /// @notice The timestamp up to which rewards are currently accruing.
    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    /// @notice Global rewards per staked token (1e18-scaled) including live accrual.
    function rewardPerToken() public view returns (uint256) {
        if (totalSupply == 0) return rewardPerTokenStored;
        return rewardPerTokenStored
            + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * PRECISION) / totalSupply;
    }

    /// @notice How many reward tokens `account` has earned and not yet claimed.
    function earned(address account) public view returns (uint256) {
        return (balanceOf[account] * (rewardPerToken() - userRewardPerTokenPaid[account])) / PRECISION
            + rewards[account];
    }

    /* ==================== USER ACTIONS ==================== */

    /// @notice Stakes `amount` of the staking token. Approve the vault first.
    function stake(uint256 amount) public nonReentrant updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();
        totalSupply += amount;
        balanceOf[msg.sender] += amount;
        if (!stakingToken.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        emit Staked(msg.sender, amount);
    }

    /// @notice Withdraws `amount` of the staking token. Accrued rewards stay claimable.
    function withdraw(uint256 amount) public nonReentrant updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();
        if (balanceOf[msg.sender] < amount) revert InsufficientStake(balanceOf[msg.sender], amount);
        totalSupply -= amount;
        balanceOf[msg.sender] -= amount;
        if (!stakingToken.transfer(msg.sender, amount)) revert TransferFailed();
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Claims all accrued rewards.
    function getReward() public nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            if (!rewardsToken.transfer(msg.sender, reward)) revert TransferFailed();
            emit RewardPaid(msg.sender, reward);
        }
    }

    /// @notice Withdraws everything and claims rewards in one call.
    function exitAll() external {
        if (balanceOf[msg.sender] > 0) withdraw(balanceOf[msg.sender]);
        getReward();
    }

    /// @notice Withdraws staked tokens while FORFEITING all pending rewards. Use when the
    ///         vault is compromised or you need principal back immediately.
    /// @dev Forfeited rewards stay in the contract (documented dust), others are unaffected.
    function emergencyWithdraw() public nonReentrant {
        uint256 amount = balanceOf[msg.sender];
        if (amount == 0) revert ZeroAmount();

        // Checkpoint globally, then detach this user without crediting them.
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        rewards[msg.sender] = 0;
        userRewardPerTokenPaid[msg.sender] = rewardPerTokenStored;
        totalSupply -= amount;
        balanceOf[msg.sender] = 0;

        if (!stakingToken.transfer(msg.sender, amount)) revert TransferFailed();
        emit EmergencyWithdrawn(msg.sender, amount);
    }

    /* ==================== OWNER: FUND EMISSIONS ==================== */

    /// @notice Funds a new emission period: pulls `amount` reward tokens from the owner and
    ///         spreads them over `duration` seconds. Can be called mid-period — leftover
    ///         rewards roll over into the new rate.
    function startRewards(uint256 amount, uint256 duration) external onlyOwner nonReentrant updateReward(address(0)) {
        if (duration == 0) revert InvalidDuration();
        if (block.timestamp >= periodFinish) {
            rewardRate = amount / duration;
        } else {
            uint256 leftover = (periodFinish - block.timestamp) * rewardRate;
            rewardRate = (amount + leftover) / duration;
        }
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + duration;
        if (!rewardsToken.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        emit RewardsNotified(amount, duration, rewardRate);
    }

    /// @notice Owner escape hatch: recover ERC-20s accidentally sent to the vault.
    /// @dev The staking token and the rewards token are PROTECTED — the owner can never
    ///      sweep user stakes or the emission pool. This bounds the trust placed in the owner.
    function recoverERC20(address tokenAddress, uint256 amount) external onlyOwner nonReentrant {
        if (tokenAddress == address(stakingToken) || tokenAddress == address(rewardsToken)) {
            revert ProtectedToken(tokenAddress);
        }
        if (amount == 0) revert ZeroAmount();
        if (!IERC20(tokenAddress).transfer(owner, amount)) revert TransferFailed();
        emit Recovered(tokenAddress, amount);
    }
}
