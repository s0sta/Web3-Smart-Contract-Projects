// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";
import {AccessControl} from "./AccessControl.sol";

/// @title MawaridTreasury
/// @notice The platform treasury: collects market fees and asset maintenance
///         contributions, pays approved vendors, and holds a reserve that even
///         governance payments cannot breach. Only the guardian can drain.
contract MawaridTreasury is AccessControl {
    /// @notice The platform operator: pays vendors, sets the reserve.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR");

    IERC20 public immutable paymentToken;

    /// @notice Reserve ratio on inflows (bps).
    uint256 public reserveBps;

    uint256 public totalFeesCollected;
    uint256 public totalPaidOut;

    /// @notice Approved vendor payments (governor-executed).
    mapping(address vendor => bool) public approvedVendors;

    event FeesReceived(address indexed from, uint256 amount);
    event VendorPaid(address indexed to, uint256 amount);
    event VendorSet(address indexed vendor, bool approved);
    event ReserveSet(uint256 bps);
    event Drained(address indexed to, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error ReserveBreach(uint256 available, uint256 needed);
    error VendorNotApproved(address vendor);
    error TransferFailed();

    constructor(IERC20 paymentToken_, uint256 reserveBps_) {
        if (address(paymentToken_) == address(0)) revert ZeroAddress();
        paymentToken = paymentToken_;
        reserveBps = reserveBps_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    receive() external payable {}

    /// @notice The secondary market routes its fees here.
    function receiveFees(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (!paymentToken.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        totalFeesCollected += amount;
        emit FeesReceived(msg.sender, amount);
    }

    /// @notice Pays a vendor while preserving the reserve floor.
    /// @dev Callable by the operator directly, or by governance via Payout proposals.
    function payVendor(address to, uint256 amount) external {
        if (!hasRole(OPERATOR_ROLE, msg.sender) && !approvedVendors[to]) revert VendorNotApproved(to);
        if (to == address(0) || amount == 0) revert ZeroAmount();

        uint256 balance = paymentToken.balanceOf(address(this));
        uint256 required = (balance * reserveBps) / 10_000;
        if (balance - amount < required) revert ReserveBreach(balance - amount, required);

        totalPaidOut += amount;
        if (!paymentToken.transfer(to, amount)) revert TransferFailed();
        emit VendorPaid(to, amount);
    }

    function setVendor(address vendor, bool approved) external onlyRole(OPERATOR_ROLE) {
        if (vendor == address(0)) revert ZeroAddress();
        approvedVendors[vendor] = approved;
        emit VendorSet(vendor, approved);
    }

    function setReserveBps(uint256 bps) external onlyRole(OPERATOR_ROLE) {
        if (bps > 10_000) revert ZeroAmount();
        reserveBps = bps;
        emit ReserveSet(bps);
    }

    /// @notice The guardian drains everything to a licensed recovery address.
    function drain(address to) external onlyRole(GUARDIAN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        uint256 balance = paymentToken.balanceOf(address(this));
        if (balance > 0) {
            if (!paymentToken.transfer(to, balance)) revert TransferFailed();
        }
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            (bool ok, ) = to.call{ value: ethBalance }("");
            if (!ok) revert TransferFailed();
        }
        emit Drained(to, balance);
    }
}
