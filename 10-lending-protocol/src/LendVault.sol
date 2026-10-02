// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./IERC20.sol";
import {ReentrancyGuard} from "./ReentrancyGuard.sol";
import {MockStable} from "./MockStable.sol";

/// @title LendVault
/// @notice A collateralized lending protocol written from scratch: users deposit ETH and borrow
///         a stablecoin against it. Debt accrues 10% APR interest per second, and positions
///         above the 80% liquidation threshold can be liquidated — liquidators repay debt and
///         seize collateral at a 10% discount.
/// @dev Prices are fixed at 2000 USD/ETH (no oracle) — see README "Production hardening".
contract LendVault is ReentrancyGuard {
    /// @notice The stablecoin the vault issues on borrow.
    IERC20 public immutable stable;

    /// @notice Fixed collateral price: 2000 USD per ETH (18-decimal fixed point).
    uint256 public constant PRICE = 2000e18;

    /// @notice Borrow up to 66% of collateral value.
    uint256 public constant LTV_BPS = 6600;

    /// @notice Liquidatable once debt exceeds 80% of collateral value.
    uint256 public constant LIQ_THRESHOLD_BPS = 8000;

    /// @notice Liquidators seize collateral worth 110% of what they repay.
    uint256 public constant LIQ_BONUS_BPS = 1000;

    /// @notice At most 50% of a position's debt can be repaid per liquidation.
    uint256 public constant CLOSE_FACTOR_BPS = 5000;

    /// @notice Borrow APR: 10% per year.
    uint256 public constant ANNUAL_RATE_BPS = 1000;

    uint256 public constant PRECISION = 1e18;

    /// @notice Per-second interest multiplier, 1e18-scaled (10% APR → ~3.17e-9 per second).
    uint256 public immutable ratePerSecond;

    /// @notice ETH collateral per user.
    mapping(address => uint256) public collateral;

    /// @notice Stablecoin debt per user (excluding live accrual — call `currentDebt`).
    mapping(address => uint256) public debt;

    /// @notice Last time each user's debt was accrued.
    mapping(address => uint256) public lastUpdate;

    uint256 public totalCollateral;
    uint256 public totalDebt;

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 amount);
    event Liquidated(address indexed user, address indexed liquidator, uint256 debtRepaid, uint256 collateralSeized);

    error ZeroAmount();
    error InsufficientCollateral(uint256 available, uint256 requested);
    error BorrowLimitExceeded(uint256 requested, uint256 limit);
    error RepayExceedsDebt(uint256 debt, uint256 amount);
    error RepayExceedsCloseFactor(uint256 maxRepay);
    error NotLiquidatable();
    error TransferFailed();
    error EthTransferFailed();

    constructor(IERC20 stable_) {
        stable = stable_;
        ratePerSecond = PRECISION * ANNUAL_RATE_BPS / 10_000 / 365 days;
    }

    /* ==================== USER ACTIONS ==================== */

    /// @notice Deposits ETH as collateral.
    function deposit() external payable nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        _accrue(msg.sender);
        collateral[msg.sender] += msg.value;
        totalCollateral += msg.value;
        emit Deposited(msg.sender, msg.value);
    }

    /// @notice Withdraws ETH as long as the remaining collateral still covers the debt at LTV.
    function withdraw(uint256 amount) external nonReentrant {
        _accrue(msg.sender);
        if (amount == 0) revert ZeroAmount();
        if (collateral[msg.sender] < amount) {
            revert InsufficientCollateral(collateral[msg.sender], amount);
        }
        uint256 remaining = collateral[msg.sender] - amount;
        uint256 limit = _maxBorrow(remaining);
        if (debt[msg.sender] > limit) revert BorrowLimitExceeded(debt[msg.sender], limit);

        collateral[msg.sender] = remaining;
        totalCollateral -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Borrows stable against collateral, capped by LTV.
    function borrow(uint256 amount) external nonReentrant {
        _accrue(msg.sender);
        if (amount == 0) revert ZeroAmount();
        uint256 limit = _maxBorrow(collateral[msg.sender]);
        if (debt[msg.sender] + amount > limit) revert BorrowLimitExceeded(debt[msg.sender] + amount, limit);

        debt[msg.sender] += amount;
        totalDebt += amount;
        MockStable(address(stable)).mint(msg.sender, amount);
        emit Borrowed(msg.sender, amount);
    }

    /// @notice Repays stable debt (exact amount). Approve the vault first.
    function repay(uint256 amount) external nonReentrant {
        _accrue(msg.sender);
        if (amount == 0) revert ZeroAmount();
        if (amount > debt[msg.sender]) revert RepayExceedsDebt(debt[msg.sender], amount);

        debt[msg.sender] -= amount;
        totalDebt -= amount;
        if (!stable.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        MockStable(address(stable)).burn(address(this), amount);
        emit Repaid(msg.sender, amount);
    }

    /// @notice Liquidates an unhealthy position: repays up to 50% of its debt and seizes
    ///         collateral worth 110% of the repayment.
    function liquidate(address user, uint256 repayAmount) external nonReentrant {
        _accrue(user);
        uint256 d = debt[user];
        if (d == 0) revert NotLiquidatable();
        if (d <= _maxBorrowAtThreshold(collateral[user])) revert NotLiquidatable();

        uint256 maxRepay = d * CLOSE_FACTOR_BPS / 10_000;
        if (repayAmount == 0 || repayAmount > maxRepay) revert RepayExceedsCloseFactor(maxRepay);

        if (!stable.transferFrom(msg.sender, address(this), repayAmount)) revert TransferFailed();
        MockStable(address(stable)).burn(address(this), repayAmount);

        debt[user] = d - repayAmount;
        totalDebt -= repayAmount;

        // Seize: USD value of the repayment plus the 10% bonus, converted to ETH.
        uint256 seizeEth = repayAmount * (10_000 + LIQ_BONUS_BPS) / 10_000 * 1e18 / PRICE;
        collateral[user] -= seizeEth;
        totalCollateral -= seizeEth;
        (bool ok,) = msg.sender.call{value: seizeEth}("");
        if (!ok) revert EthTransferFailed();
        emit Liquidated(user, msg.sender, repayAmount, seizeEth);
    }

    /* ==================== VIEWS ==================== */

    /// @notice Debt including interest accrued since the last update.
    function currentDebt(address user) public view returns (uint256) {
        uint256 d = debt[user];
        return d + d * ratePerSecond * (block.timestamp - lastUpdate[user]) / PRECISION;
    }

    /// @notice How much more stable `user` can borrow right now.
    function maxBorrow(address user) external view returns (uint256) {
        uint256 limit = _maxBorrow(collateral[user]);
        uint256 d = currentDebt(user);
        return limit > d ? limit - d : 0;
    }

    /// @notice 1e18 = exactly at the liquidation threshold; below 1e18 = liquidatable.
    function healthFactor(address user) external view returns (uint256) {
        uint256 d = currentDebt(user);
        if (d == 0) return type(uint256).max;
        return _maxBorrowAtThreshold(collateral[user]) * PRECISION / d;
    }

    function liquidatable(address user) external view returns (bool) {
        uint256 d = currentDebt(user);
        return d != 0 && d > _maxBorrowAtThreshold(collateral[user]);
    }

    /* ==================== INTERNALS ==================== */

    /// @notice Maximum stable borrowable against `collat` ETH at the LTV (66%).
    function _maxBorrow(uint256 collat) internal pure returns (uint256) {
        return collat * PRICE / 1e18 * LTV_BPS / 10_000;
    }

    /// @notice Debt ceiling at the liquidation threshold (80% of collateral value).
    function _maxBorrowAtThreshold(uint256 collat) internal pure returns (uint256) {
        return collat * PRICE / 1e18 * LIQ_THRESHOLD_BPS / 10_000;
    }

    /// @notice Compounds the user's interest since their last interaction.
    function _accrue(address user) internal {
        uint256 d = debt[user];
        if (d > 0) {
            uint256 growth = d * ratePerSecond * (block.timestamp - lastUpdate[user]) / PRECISION;
            debt[user] = d + growth;
            totalDebt += growth;
        }
        lastUpdate[user] = block.timestamp;
    }
}
