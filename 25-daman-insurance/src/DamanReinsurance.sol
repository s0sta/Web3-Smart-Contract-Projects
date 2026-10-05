// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {DamanPremiums} from "./DamanPremiums.sol";
import {DamanLines} from "./DamanPricing.sol";

/// @title DamanReinsurance
/// @notice The tail-risk pool: the mutual cedes a share of each line's premium
///         income here; claims above the attachment point recover from this
///         pool, protecting the line pools from large losses.
contract DamanReinsurance is AccessControl {
    /// @notice The premiums desk cedes and recovers.
    bytes32 public constant PREMIUMS_ROLE = keccak256("PREMIUMS");

    /// @notice Cession share of each premium (bps) and attachment point per
    ///         line (claims above this recover).
    uint256 public cessionBps;
    mapping(DamanLines.Line line => uint256) public attachmentPoint;
    mapping(DamanLines.Line line => uint256) public recoveryRatioBps;

    /// @notice Reinsurance pool per line.
    mapping(DamanLines.Line line => uint256) public pool;

    uint256 public totalCeded;
    uint256 public totalRecovered;

    DamanPremiums public immutable premiums;
    IERC20 public immutable paymentToken;

    event CededToRe(DamanLines.Line line, uint256 amount);
    event RecoveryRequested(DamanLines.Line line, uint256 claim, uint256 recovery);
    event ParamsSet(uint256 cessionBps);

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientRePool(DamanLines.Line line, uint256 available, uint256 needed);
    error TransferFailed();

    constructor(DamanPremiums premiums_, IERC20 paymentToken_) {
        if (address(premiums_) == address(0) || address(paymentToken_) == address(0)) revert ZeroAddress();
        premiums = premiums_;
        paymentToken = paymentToken_;
        cessionBps = 1500; // 15% of premiums
        attachmentPoint[DamanLines.Line.Property] = 10_000 ether;
        attachmentPoint[DamanLines.Line.Health] = 5_000 ether;
        attachmentPoint[DamanLines.Line.Travel] = 1_000 ether;
        attachmentPoint[DamanLines.Line.FlightDelay] = 500 ether;
        recoveryRatioBps[DamanLines.Line.Property] = 9000; // 90%
        recoveryRatioBps[DamanLines.Line.Health] = 8000;
        recoveryRatioBps[DamanLines.Line.Travel] = 9000;
        recoveryRatioBps[DamanLines.Line.FlightDelay] = 9000;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PREMIUMS_ROLE, msg.sender);
    }

    /// @notice The operator seeds the reinsurance pool.
    function fundPool(DamanLines.Line line, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (amount == 0) revert ZeroAmount();
        if (!paymentToken.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        pool[line] += amount;
        totalCeded += amount;
        emit CededToRe(line, amount);
    }

    /* ==================== CESSION ==================== */

    /// @notice The premiums desk cedes a share of each received premium.
    function cedeShare(DamanLines.Line line, uint256 premiumAmount) external onlyRole(PREMIUMS_ROLE) {
        uint256 share = (premiumAmount * cessionBps) / 10_000;
        if (share == 0) return;
        premiums.cede(line, share);
        pool[line] += share;
        totalCeded += share;
        emit CededToRe(line, share);
    }

    /* ==================== RECOVERIES ==================== */

    /// @notice The premiums desk requests a recovery for a large claim.
    function recover(DamanLines.Line line, uint256 claimAmount) external onlyRole(PREMIUMS_ROLE) returns (uint256 recovery) {
        uint256 attachment = attachmentPoint[line];
        if (claimAmount <= attachment) return 0;
        recovery = ((claimAmount - attachment) * recoveryRatioBps[line]) / 10_000;
        uint256 available = pool[line];
        if (available < recovery) revert InsufficientRePool(line, available, recovery);
        pool[line] -= recovery;
        totalRecovered += recovery;
        if (!paymentToken.transfer(msg.sender, recovery)) revert TransferFailed();
        emit RecoveryRequested(line, claimAmount, recovery);
    }

    /* ==================== ADMIN ==================== */

    function setParams(uint256 cessionBps_, DamanLines.Line line, uint256 attachment, uint256 recoveryRatioBps_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (cessionBps_ > 5000 || recoveryRatioBps_ > 10_000) revert ZeroAmount();
        cessionBps = cessionBps_;
        attachmentPoint[line] = attachment;
        recoveryRatioBps[line] = recoveryRatioBps_;
        emit ParamsSet(cessionBps_);
    }
}
