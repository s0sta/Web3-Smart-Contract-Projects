// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";
import {AccessControl} from "./AccessControl.sol";
import {Checkpoints} from "./lib/Checkpoints.sol";

/// @title TamweelVault
/// @notice The deposit side of the bank: depositors put the payment stable in and
///         receive vault shares (from-scratch share accounting, ERC-4626-style),
///         which earn the supply rate and are the governance weight. Withdrawals
///         are limited by the liquid assets the bank holds.
contract TamweelVault is AccessControl {
    using Checkpoints for Checkpoints.Checkpoint[];

    /// @notice The markets contract deposits the borrowed liquidity here.
    bytes32 public constant MARKETS_ROLE = keccak256("MARKETS");

    /// @notice The insurance fund can inject bad-debt coverage.
    bytes32 public constant INSURANCE_ROLE = keccak256("INSURANCE");

    IERC20 public immutable asset;

    uint256 public totalAssets; // deposited + injected coverage
    uint256 public totalSupply; // vault shares
    uint256 public borrowedAssets; // currently lent to the markets

    mapping(address holder => uint256) public balanceOf;
    mapping(address holder => Checkpoints.Checkpoint[]) private _shareHistory;

    /// @notice Minimum liquid buffer (bps of deposits) that withdrawals cannot breach.
    uint256 public liquidityBufferBps;

    event Deposit(address indexed holder, uint256 assets, uint256 shares);
    event Withdraw(address indexed holder, uint256 assets, uint256 shares);
    event LentToMarkets(uint256 amount);
    event RecoveredFromMarkets(uint256 amount);
    event CoverageInjected(uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientShares(uint256 shares, uint256 amount);
    error InsufficientLiquidity(uint256 available, uint256 needed);
    error TransferFailed();

    constructor(IERC20 asset_, uint256 liquidityBufferBps_) {
        if (address(asset_) == address(0)) revert ZeroAddress();
        asset = asset_;
        liquidityBufferBps = liquidityBufferBps_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MARKETS_ROLE, msg.sender);
        _grantRole(INSURANCE_ROLE, msg.sender);
    }

    /* ==================== DEPOSITS & WITHDRAWALS ==================== */

    function deposit(uint256 amount) external returns (uint256 shares_) {
        if (amount == 0) revert ZeroAmount();
        if (!asset.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        shares_ = totalSupply == 0 ? amount : (amount * totalSupply) / totalAssets;
        _mint(msg.sender, shares_);
        totalAssets += amount;
        emit Deposit(msg.sender, amount, shares_);
    }

    function withdraw(uint256 shares_) external returns (uint256 amount) {
        if (shares_ == 0) revert ZeroAmount();
        if (balanceOf[msg.sender] < shares_) revert InsufficientShares(balanceOf[msg.sender], shares_);

        amount = (shares_ * totalAssets) / totalSupply;
        uint256 liquid = asset.balanceOf(address(this)) - borrowedAssets;
        uint256 required = (totalAssets * liquidityBufferBps) / 10_000;
        uint256 available = liquid > required ? liquid - required : 0;
        if (amount > available) revert InsufficientLiquidity(available, amount);

        _burn(msg.sender, shares_);
        totalAssets -= amount;
        if (!asset.transfer(msg.sender, amount)) revert TransferFailed();
        emit Withdraw(msg.sender, amount, shares_);
    }

    function previewRedeem(uint256 shares_) public view returns (uint256) {
        if (totalSupply == 0) return 0;
        return (shares_ * totalAssets) / totalSupply;
    }

    /* ==================== LIQUIDITY PROVISION ==================== */

    /// @notice The markets borrow liquidity for under-collateralized positions.
    function lendToMarkets(uint256 amount) external onlyRole(MARKETS_ROLE) {
        uint256 liquid = asset.balanceOf(address(this)) - borrowedAssets;
        uint256 required = (totalAssets * liquidityBufferBps) / 10_000;
        uint256 available = liquid > required ? liquid - required : 0;
        if (amount > available) revert InsufficientLiquidity(available, amount);
        borrowedAssets += amount;
        if (!asset.transfer(msg.sender, amount)) revert TransferFailed();
        emit LentToMarkets(amount);
    }

    /// @notice The markets notify the vault that liquidity has been returned.
    /// @dev The funds arrive from the borrower directly (transferFrom to the vault);
    ///      this call only adjusts the bookkeeping.
    function recoverFromMarkets(uint256 amount) external onlyRole(MARKETS_ROLE) {
        if (amount == 0) revert ZeroAmount();
        borrowedAssets = amount > borrowedAssets ? 0 : borrowedAssets - amount;
        emit RecoveredFromMarkets(amount);
    }

    /// @notice The insurance fund injects coverage (increases totalAssets).
    function injectCoverage(uint256 amount) external onlyRole(INSURANCE_ROLE) {
        if (amount == 0) revert ZeroAmount();
        if (!asset.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        totalAssets += amount;
        emit CoverageInjected(amount);
    }

    /* ==================== SNAPSHOTS ==================== */

    function getPastShares(address holder, uint256 blockNumber) external view returns (uint256) {
        return _shareHistory[holder].lookup(blockNumber);
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
        _shareHistory[to].write(_shareHistory[to].latest(), balanceOf[to]);
    }

    function _burn(address from, uint256 amount) internal {
        totalSupply -= amount;
        balanceOf[from] -= amount;
        _shareHistory[from].write(_shareHistory[from].latest(), balanceOf[from]);
    }
}
