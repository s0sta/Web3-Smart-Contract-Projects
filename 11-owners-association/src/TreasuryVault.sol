// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";
import {AccessControl} from "./AccessControl.sol";

/// @title TreasuryVault
/// @notice The association's funds: service charges arrive here, and money leaves only
///         through (a) governance-executed payments, (b) the board's registered payments
///         below a ceiling, or (c) a guardian emergency drain. A minimum reserve is
///         enforced so the building can never be emptied below its statutory safety net.
/// @dev Mirrors the discipline Dubai's jointly owned property law imposes on owners'
///      association funds (service-charge accounts, reserve funds, audit trails).
contract TreasuryVault is AccessControl {
    /// @notice Payments may be made by governance (via proposals) or directly by the board.
    bytes32 public constant TREASURER_ROLE = keccak256("TREASURER");

    /// @notice The stablecoin the treasury holds.
    IERC20 public immutable token;

    /// @notice The governance authority that executes proposal-driven payments.
    address public authority;

    /// @notice Minimum reserve: basis points of the current balance that must remain
    ///         after any non-emergency payment (500 = 5%).
    uint256 public reserveBps;

    /// @notice The largest payment the board may make without a full proposal.
    uint256 public boardPaymentCeiling;

    /// @notice Board-direct payments made in the last 30 days (rolling ceiling).
    uint256 public boardSpent30d;
    uint256 public boardWindowStart;

    /// @notice Running total paid out to vendors since inception.
    uint256 public totalPaidOut;

    /// @notice Running total of the building's maintenance fund (earmarked reserve share).
    uint256 public maintenanceFund;

    event PaymentMade(address indexed to, uint256 amount, address indexed by, bool indexed viaProposal);
    event MaintenanceAllocated(uint256 amount);
    event EmergencyDrain(address indexed to, uint256 amount);
    event ReserveSet(uint256 reserveBps);
    event CeilingSet(uint256 ceiling);
    event Received(address indexed from, uint256 amount);

    error ZeroAddress();
    error NotAuthority(address caller);
    error ReserveBreach(uint256 required, uint256 available);
    error BoardCeilingBreach(uint256 spent, uint256 ceiling);
    error ZeroAmount();
    error TransferFailed();
    error ProtectedToken();

    modifier onlyAuthority() {
        if (msg.sender != authority) revert NotAuthority(msg.sender);
        _;
    }

    constructor(IERC20 token_, address initialAuthority) {
        if (address(token_) == address(0) || initialAuthority == address(0)) revert ZeroAddress();
        token = token_;
        authority = initialAuthority;
        reserveBps = 500; // 5%
        boardPaymentCeiling = 10_000 ether; // demo ceiling in AED-S
    }

    /// @notice Re-points the governance authority (deploy-time two-step wiring).
    function setAuthority(address newAuthority) external onlyAuthority {
        if (newAuthority == address(0)) revert ZeroAddress();
        authority = newAuthority;
    }

    /// @notice Accepts stable donations/transfers from anyone (permissionless deposit path;
    ///         service-charge payments arrive via direct transfers from the registry).
    function receiveStable(uint256 amount) external {
        if (!token.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        emit Received(msg.sender, amount);
    }

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    /* ==================== PAYMENTS ==================== */

    /// @notice Governance-executed payment: a passed Payment proposal calls this.
    /// @dev Enforces the minimum reserve. The governor is the caller.
    function payVendor(address to, uint256 amount) external onlyAuthority {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _pay(to, amount, msg.sender, true);
    }

    /// @notice Board-direct payment below the rolling 30-day ceiling.
    function boardPayVendor(address to, uint256 amount) external onlyRole(TREASURER_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _rollWindow();
        if (boardSpent30d + amount > boardPaymentCeiling) {
            revert BoardCeilingBreach(boardSpent30d + amount, boardPaymentCeiling);
        }
        boardSpent30d += amount;
        _pay(to, amount, msg.sender, false);
    }

    /// @notice Earmarks funds for the maintenance fund (part of a Budget proposal).
    function allocateMaintenance(uint256 amount) external onlyAuthority {
        if (amount == 0) revert ZeroAmount();
        if (token.balanceOf(address(this)) - maintenanceFund < amount) revert ReserveBreach(amount, token.balanceOf(address(this)) - maintenanceFund);
        maintenanceFund += amount;
        emit MaintenanceAllocated(amount);
    }

    /// @notice Guardian-only emergency drain: bypasses the reserve.
    function emergencyDrain(address to) external onlyRole(GUARDIAN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = token.balanceOf(address(this));
        if (bal == 0) return;
        if (!token.transfer(to, bal)) revert TransferFailed();
        emit EmergencyDrain(to, bal);
    }

    function _pay(address to, uint256 amount, address by, bool viaProposal) internal {
        // The minimum reserve is ALWAYS enforced — even proposal-executed payments
        // cannot empty the building's safety net. Only the guardian drain bypasses it.
        uint256 bal = token.balanceOf(address(this));
        uint256 required = (bal * reserveBps) / 10_000;
        if (bal - amount < required) revert ReserveBreach(required, bal);
        if (!token.transfer(to, amount)) revert TransferFailed();
        totalPaidOut += amount;
        emit PaymentMade(to, amount, by, viaProposal);
    }

    /// @notice Governance may re-configure the reserve ratio.
    function setReserveBps(uint256 bps) external onlyAuthority {
        if (bps > 10_000) revert ReserveBreach(bps, 10_000);
        reserveBps = bps;
        emit ReserveSet(bps);
    }

    /// @notice Governance may raise or lower the board's rolling payment ceiling.
    function setBoardPaymentCeiling(uint256 ceiling) external onlyAuthority {
        boardPaymentCeiling = ceiling;
        emit CeilingSet(ceiling);
    }

    /// @notice Escape hatch for tokens accidentally sent to the treasury.
    /// @dev The treasury's own token is protected — service-charge funds can only leave
    ///      through the payment paths above.
    function recoverERC20(IERC20 stray, address to) external onlyAuthority {
        if (address(stray) == address(token)) revert ProtectedToken();
        uint256 bal = stray.balanceOf(address(this));
        if (bal == 0) return;
        if (!stray.transfer(to, bal)) revert TransferFailed();
    }

    function _rollWindow() internal {
        if (block.timestamp - boardWindowStart >= 30 days) {
            boardWindowStart = block.timestamp;
            boardSpent30d = 0;
        }
    }
}
