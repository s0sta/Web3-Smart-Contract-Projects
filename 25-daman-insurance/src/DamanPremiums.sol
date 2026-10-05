// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {DamanLines} from "./DamanPricing.sol";

/// @title DamanPremiums
/// @notice The per-line solvency pools: premiums accumulate per insurance line;
///         claims and parametric payouts draw from the matching pool; the
///         reinsurance desk cedes a share; the operator monitors solvency.
contract DamanPremiums is AccessControl {
    /// @notice The claims, parametric and reinsurance desks draw from pools.
    bytes32 public constant CLAIMS_ROLE = keccak256("CLAIMS");
    bytes32 public constant PARAMETRIC_ROLE = keccak256("PARAMETRIC");
    bytes32 public constant REINSURANCE_ROLE = keccak256("REINSURANCE");
    bytes32 public constant SURPLUS_ROLE = keccak256("SURPLUS");

    /// @notice Per-line pool balances and payout history.
    mapping(DamanLines.Line line => uint256) public pool;
    mapping(DamanLines.Line line => uint256) public totalPremiums;
    mapping(DamanLines.Line line => uint256) public totalPaidOut;

    IERC20 public immutable paymentToken;

    event PremiumReceived(DamanLines.Line line, uint256 amount);
    event Payout(DamanLines.Line line, uint256 amount);
    event Ceded(DamanLines.Line line, uint256 amount);
    event Recovered(DamanLines.Line line, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientPool(DamanLines.Line line, uint256 available, uint256 needed);
    error TransferFailed();

    constructor(IERC20 paymentToken_) {
        if (address(paymentToken_) == address(0)) revert ZeroAddress();
        paymentToken = paymentToken_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(CLAIMS_ROLE, msg.sender);
        _grantRole(PARAMETRIC_ROLE, msg.sender);
        _grantRole(REINSURANCE_ROLE, msg.sender);
        _grantRole(SURPLUS_ROLE, msg.sender);
    }

    /* ==================== FLOWS ==================== */

    /// @notice The operator seeds a line pool with capital.
    function fundPool(DamanLines.Line line, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (amount == 0) revert ZeroAmount();
        if (!paymentToken.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        pool[line] += amount;
        totalPremiums[line] += amount;
        emit PremiumReceived(line, amount);
    }

    function receivePremium(DamanLines.Line line, uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (!paymentToken.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        pool[line] += amount;
        totalPremiums[line] += amount;
        emit PremiumReceived(line, amount);
    }

    /// @notice The claims desk pays a claim from the line pool.
    function payClaim(DamanLines.Line line, uint256 amount, address to) external onlyRole(CLAIMS_ROLE) {
        _payout(line, amount, to);
    }

    /// @notice The parametric desk pays an auto-triggered payout.
    function payParametric(DamanLines.Line line, uint256 amount, address to) external onlyRole(PARAMETRIC_ROLE) {
        _payout(line, amount, to);
    }

    /// @notice The surplus desk pays mutual rebates from the line pool.
    function paySurplus(DamanLines.Line line, uint256 amount, address to) external onlyRole(SURPLUS_ROLE) {
        _payout(line, amount, to);
    }

    function _payout(DamanLines.Line line, uint256 amount, address to) internal {
        if (amount == 0) revert ZeroAmount();
        uint256 available = pool[line];
        if (available < amount) revert InsufficientPool(line, available, amount);
        pool[line] -= amount;
        totalPaidOut[line] += amount;
        if (!paymentToken.transfer(to, amount)) revert TransferFailed();
        emit Payout(line, amount);
    }

    /// @notice The reinsurance desk cedes a share of premiums to its pool.
    function cede(DamanLines.Line line, uint256 amount) external onlyRole(REINSURANCE_ROLE) {
        if (amount == 0) revert ZeroAmount();
        uint256 available = pool[line];
        if (available < amount) revert InsufficientPool(line, available, amount);
        pool[line] -= amount;
        if (!paymentToken.transfer(msg.sender, amount)) revert TransferFailed();
        emit Ceded(line, amount);
    }

    /// @notice The reinsurance desk returns recoveries into the line pool.
    function recover(DamanLines.Line line, uint256 amount) external onlyRole(REINSURANCE_ROLE) {
        if (amount == 0) revert ZeroAmount();
        if (!paymentToken.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        pool[line] += amount;
        emit Recovered(line, amount);
    }

    /// @notice Total premiums across all lines (for the governor's quorum).
    function totalPremiumsSum() external view returns (uint256 total) {
        total = totalPremiums[DamanLines.Line.Travel]
            + totalPremiums[DamanLines.Line.FlightDelay]
            + totalPremiums[DamanLines.Line.Property]
            + totalPremiums[DamanLines.Line.Health];
    }

    /// @notice The pool solvency ratio (pool vs outstanding cover, bps).
    function solvencyBps(DamanLines.Line line, uint256 outstandingCover) external view returns (uint256) {
        if (outstandingCover == 0) return 10_000;
        return (pool[line] * 10_000) / outstandingCover;
    }
}
