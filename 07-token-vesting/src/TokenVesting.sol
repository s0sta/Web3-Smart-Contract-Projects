// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./IERC20.sol";
import {Ownable} from "./Ownable.sol";
import {ReentrancyGuard} from "./ReentrancyGuard.sol";

/// @title TokenVesting
/// @notice Cliff + linear token vesting written from scratch — the standard way teams,
///         investors and advisors receive tokens. The owner creates funded, revocable
///         schedules; beneficiaries pull their vested tokens over time.
/// @dev One schedule per beneficiary. Tokens are deposited into this contract when the
///      schedule is created, so claims are always backed by real balance.
contract TokenVesting is Ownable, ReentrancyGuard {
    /// @notice A funded vesting schedule.
    struct Schedule {
        uint256 totalAmount; // full grant, deposited at creation
        uint256 claimed; // already withdrawn by the beneficiary
        uint256 start; // vesting start timestamp
        uint256 cliff; // nothing vests before this timestamp
        uint256 end; // everything vests by this timestamp
        bool revoked; // true after the owner revokes the unvested portion
        uint256 revokedAt; // when it was revoked (0 = active); accrual is capped here
    }

    /// @notice The token being vested.
    IERC20 public immutable token;

    /// @notice Schedules by beneficiary.
    mapping(address => Schedule) public schedules;

    event ScheduleCreated(address indexed beneficiary, uint256 amount, uint256 start, uint256 cliff, uint256 end);
    event Claimed(address indexed beneficiary, uint256 amount);
    event ScheduleRevoked(address indexed beneficiary, uint256 returnedToOwner);

    error ZeroAmount();
    error InvalidSchedule();
    error ScheduleExists(address beneficiary);
    error NoSchedule(address beneficiary);
    error NothingToClaim(address beneficiary);
    error AlreadyRevoked(address beneficiary);
    error TransferFailed();

    constructor(IERC20 token_, address initialOwner) Ownable(initialOwner) {
        if (address(token_) == address(0)) revert ZeroAddress();
        token = token_;
    }

    /* ==================== VESTING MATH ==================== */

    /// @notice How many tokens have vested for `beneficiary` right now.
    /// @dev Accrual is capped at `revokedAt` for revoked schedules, so a beneficiary keeps
    ///      exactly what the curve granted them by revocation time — nothing more.
    function vestedAmount(address beneficiary) public view returns (uint256) {
        Schedule storage s = schedules[beneficiary];
        if (s.totalAmount == 0) return 0;
        uint256 now_ = block.timestamp;
        if (s.revokedAt != 0 && now_ > s.revokedAt) now_ = s.revokedAt;
        if (now_ < s.cliff) return 0; // before cliff: nothing
        if (now_ >= s.end) return s.totalAmount; // finished: everything
        return (s.totalAmount * (now_ - s.cliff)) / (s.end - s.cliff); // linear between cliff and end
    }

    /// @notice Vested minus already claimed — what `claim()` would pay out today.
    function releasable(address beneficiary) public view returns (uint256) {
        return vestedAmount(beneficiary) - schedules[beneficiary].claimed;
    }

    /* ==================== OWNER ==================== */

    /// @notice Creates a funded schedule: pulls `totalAmount` tokens from the owner now and
    ///         vests them for `beneficiary` — cliff, then linearly until the end.
    /// @param start When vesting starts (may be past or future).
    /// @param cliffDuration Seconds from `start` until the cliff.
    /// @param vestingDuration Seconds of linear vesting *after* the cliff.
    function createSchedule(
        address beneficiary,
        uint256 totalAmount,
        uint256 start,
        uint256 cliffDuration,
        uint256 vestingDuration
    ) external onlyOwner {
        if (beneficiary == address(0)) revert ZeroAddress();
        if (totalAmount == 0) revert ZeroAmount();
        if (cliffDuration == 0 || vestingDuration == 0) revert InvalidSchedule();
        if (schedules[beneficiary].totalAmount != 0) revert ScheduleExists(beneficiary);

        schedules[beneficiary] = Schedule({
            totalAmount: totalAmount,
            claimed: 0,
            start: start,
            cliff: start + cliffDuration,
            end: start + cliffDuration + vestingDuration,
            revoked: false,
            revokedAt: 0
        });

        if (!token.transferFrom(msg.sender, address(this), totalAmount)) revert TransferFailed();
        emit ScheduleCreated(beneficiary, totalAmount, start, start + cliffDuration, start + cliffDuration + vestingDuration);
    }

    /// @notice Revokes a schedule: the unvested portion returns to the owner, the beneficiary
    ///         keeps whatever has already vested (still claimable). Accrual is frozen at the
    ///         revocation timestamp.
    function revokeSchedule(address beneficiary) external onlyOwner {
        Schedule storage s = schedules[beneficiary];
        if (s.totalAmount == 0) revert NoSchedule(beneficiary);
        if (s.revoked) revert AlreadyRevoked(beneficiary);

        uint256 vested = vestedAmount(beneficiary);
        uint256 unvested = s.totalAmount - vested;
        s.revoked = true;
        s.revokedAt = block.timestamp;

        if (unvested > 0) {
            if (!token.transfer(owner, unvested)) revert TransferFailed();
        }
        emit ScheduleRevoked(beneficiary, unvested);
    }

    /* ==================== BENEFICIARY ==================== */

    /// @notice Claims all currently vested, unclaimed tokens.
    function claim() external nonReentrant {
        Schedule storage s = schedules[msg.sender];
        if (s.totalAmount == 0) revert NoSchedule(msg.sender);
        uint256 amount = vestedAmount(msg.sender) - s.claimed;
        if (amount == 0) revert NothingToClaim(msg.sender);

        s.claimed += amount;
        if (!token.transfer(msg.sender, amount)) revert TransferFailed();
        emit Claimed(msg.sender, amount);
    }
}
