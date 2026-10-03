// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";
import {AccessControl} from "./AccessControl.sol";
import {MawaridShares} from "./MawaridShares.sol";
import {MawaridCompliance} from "./MawaridCompliance.sol";

/// @title MawaridSecondaryMarket
/// @notice The OTC venue for tokenized shares: sellers place limit sell orders
///         (escrowed shares), buyers fill them at the ask price, and the platform
///         takes a fee routed to the treasury. Orders are cancelable until filled.
contract MawaridSecondaryMarket is AccessControl {
    /// @notice The platform operator: sets the fee.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR");

    /// @notice One limit sell order.
    struct Order {
        uint256 assetId;
        address seller;
        uint256 amount;
        uint256 remaining;
        uint256 pricePerShare; // in the payment token
        bool active;
    }

    Order[] public orders;

    MawaridShares public immutable shares;
    MawaridCompliance public immutable compliance;
    IERC20 public immutable paymentToken;
    address public treasury;

    /// @notice Platform fee on filled volume (bps).
    uint256 public feeBps;

    /// @notice Lifetime volume and fees.
    uint256 public totalVolume;
    uint256 public totalFees;

    event OrderPlaced(uint256 indexed orderId, uint256 indexed assetId, address indexed seller, uint256 amount, uint256 pricePerShare);
    event OrderFilled(uint256 indexed orderId, address indexed buyer, uint256 amount, uint256 paid);
    event OrderCanceled(uint256 indexed orderId);
    event FeeSet(uint256 bps);
    event TreasurySet(address treasury);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownOrder(uint256 orderId);
    error OrderInactive(uint256 orderId);
    error SelfFill(address trader);
    error InsufficientOrderSize(uint256 requested, uint256 remaining);
    error TransferFailed();
    error NotSeller(uint256 orderId);

    constructor(
        MawaridShares shares_,
        MawaridCompliance compliance_,
        IERC20 paymentToken_,
        address treasury_,
        uint256 feeBps_
    ) {
        if (address(shares_) == address(0) || address(compliance_) == address(0) || address(paymentToken_) == address(0) || treasury_ == address(0)) {
            revert ZeroAddress();
        }
        shares = shares_;
        compliance = compliance_;
        paymentToken = paymentToken_;
        treasury = treasury_;
        feeBps = feeBps_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    /* ==================== ORDERS ==================== */

    /// @notice Places a limit sell order; the shares are escrowed here.
    function placeOrder(uint256 assetId, uint256 amount, uint256 pricePerShare) external returns (uint256 orderId) {
        if (amount == 0 || pricePerShare == 0) revert ZeroAmount();
        if (!compliance.canHold(assetId, msg.sender)) revert();
        if (!shares.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();

        orderId = orders.length;
        orders.push(
            Order({ assetId: assetId, seller: msg.sender, amount: amount, remaining: amount, pricePerShare: pricePerShare, active: true })
        );
        emit OrderPlaced(orderId, assetId, msg.sender, amount, pricePerShare);
    }

    /// @notice Fills (part of) an order at the ask price.
    function fillOrder(uint256 orderId, uint256 amount) external {
        Order storage o = orders[orderId];
        if (o.pricePerShare == 0) revert UnknownOrder(orderId);
        if (!o.active) revert OrderInactive(orderId);
        if (msg.sender == o.seller) revert SelfFill(msg.sender);
        if (amount > o.remaining) revert InsufficientOrderSize(amount, o.remaining);
        if (!compliance.canHold(o.assetId, msg.sender)) revert();

        uint256 cost = (amount * o.pricePerShare) / 1e18;
        uint256 fee = (cost * feeBps) / 10_000;
        uint256 net = cost - fee;

        // buyer pays: net to seller, fee to the treasury
        if (!paymentToken.transferFrom(msg.sender, o.seller, net)) revert TransferFailed();
        if (fee > 0) {
            if (!paymentToken.transferFrom(msg.sender, treasury, fee)) revert TransferFailed();
        }
        // escrowed shares move to the buyer
        if (!shares.transfer(msg.sender, amount)) revert TransferFailed();

        o.remaining -= amount;
        if (o.remaining == 0) o.active = false;
        totalVolume += amount;
        totalFees += fee;
        emit OrderFilled(orderId, msg.sender, amount, cost);
    }

    /// @notice Cancels the unfilled remainder of an order.
    function cancelOrder(uint256 orderId) external {
        Order storage o = orders[orderId];
        if (o.pricePerShare == 0) revert UnknownOrder(orderId);
        if (!o.active) revert OrderInactive(orderId);
        if (msg.sender != o.seller) revert NotSeller(orderId);

        o.active = false;
        uint256 remainder = o.remaining;
        o.remaining = 0;
        if (!shares.transfer(msg.sender, remainder)) revert TransferFailed();
        emit OrderCanceled(orderId);
    }

    /* ==================== ADMIN ==================== */

    function setFeeBps(uint256 bps) external onlyRole(OPERATOR_ROLE) {
        if (bps > 10_000) revert ZeroAmount();
        feeBps = bps;
        emit FeeSet(bps);
    }

    function setTreasury(address treasury_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }
}
