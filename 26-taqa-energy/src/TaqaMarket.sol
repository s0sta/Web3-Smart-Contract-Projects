// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {TaqaRegistry} from "./TaqaRegistry.sol";
import {TaqaCertificates} from "./TaqaCertificates.sol";
import {TaqaCarbon} from "./TaqaCarbon.sol";
import {TaqaTreasury} from "./TaqaTreasury.sol";

/// @title TaqaMarket
/// @notice The certificate/credit exchange: escrowed limit orders in the
///         settlement stable with fills at the ask and fees to the treasury.
contract TaqaMarket is AccessControl {
    /// @notice The operator manages fees.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR");

    /// @notice Asset kinds.
    enum AssetKind { Rec, Carbon }

    /// @notice One resting order.
    struct Order {
        address seller;
        AssetKind kind;
        uint256 price; // stable per certificate/tonne
        uint256 amount;
        bool active;
    }

    Order[] public orders;

    uint256 public feeBps;
    uint256 public totalVolume;

    TaqaRegistry public immutable registry;
    TaqaCertificates public immutable certificates;
    TaqaCarbon public immutable carbon;
    TaqaTreasury public immutable treasury;
    IERC20 public immutable paymentToken;

    event OrderPlaced(uint256 indexed orderId, address indexed seller, AssetKind kind, uint256 price, uint256 amount);
    event OrderFilled(uint256 indexed orderId, address indexed buyer, uint256 amount, uint256 cost);
    event OrderCanceled(uint256 indexed orderId);
    event FeeSet(uint256 bps);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownOrder(uint256 orderId);
    error OrderInactive(uint256 orderId);
    error NotSeller(uint256 orderId);
    error SelfFill(address trader);
    error InsufficientAssets(uint256 balance, uint256 amount);
    error TransferFailed();

    constructor(
        TaqaRegistry registry_,
        TaqaCertificates certificates_,
        TaqaCarbon carbon_,
        TaqaTreasury treasury_,
        IERC20 paymentToken_
    ) {
        if (address(registry_) == address(0) || address(certificates_) == address(0) || address(carbon_) == address(0) || address(treasury_) == address(0) || address(paymentToken_) == address(0)) {
            revert ZeroAddress();
        }
        registry = registry_;
        certificates = certificates_;
        carbon = carbon_;
        treasury = treasury_;
        paymentToken = paymentToken_;
        feeBps = 50; // 0.5%
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    /* ==================== ORDERS ==================== */

    function placeOrder(AssetKind kind, uint256 price, uint256 amount) external returns (uint256 orderId) {
        if (price == 0 || amount == 0) revert ZeroAmount();
        if (!registry.isActive(msg.sender)) revert ZeroAmount();
        // escrow the assets
        if (kind == AssetKind.Rec) {
            if (certificates.balanceOf(msg.sender) < amount) revert InsufficientAssets(certificates.balanceOf(msg.sender), amount);
            certificates.transferFromMarket(msg.sender, address(this), amount);
        } else {
            if (carbon.balanceOf(msg.sender) < amount) revert InsufficientAssets(carbon.balanceOf(msg.sender), amount);
            carbon.transferFromMarket(msg.sender, address(this), amount);
        }
        orderId = orders.length;
        orders.push();
        Order storage o = orders[orderId];
        o.seller = msg.sender;
        o.kind = kind;
        o.price = price;
        o.amount = amount;
        o.active = true;
        emit OrderPlaced(orderId, msg.sender, kind, price, amount);
    }

    function cancelOrder(uint256 orderId) external {
        Order storage o = orders[orderId];
        if (o.seller == address(0)) revert UnknownOrder(orderId);
        if (msg.sender != o.seller) revert NotSeller(orderId);
        if (!o.active) revert OrderInactive(orderId);
        o.active = false;
        if (o.kind == AssetKind.Rec) {
            certificates.transferFromMarket(address(this), o.seller, o.amount);
        } else {
            carbon.transferFromMarket(address(this), o.seller, o.amount);
        }
        emit OrderCanceled(orderId);
    }

    function fill(uint256 orderId, uint256 amount) external {
        Order storage o = orders[orderId];
        if (o.seller == address(0)) revert UnknownOrder(orderId);
        if (msg.sender == o.seller) revert SelfFill(msg.sender);
        if (!o.active) revert OrderInactive(orderId);
        if (amount == 0 || amount > o.amount) revert OrderInactive(orderId);

        uint256 cost = amount * o.price; // price is stable-per-unit, amount is raw units
        uint256 fee = (cost * feeBps) / 10_000;
        o.amount -= amount;
        if (o.amount == 0) o.active = false;

        if (!paymentToken.transferFrom(msg.sender, o.seller, cost - fee)) revert TransferFailed();
        if (o.kind == AssetKind.Rec) {
            certificates.transferFromMarket(address(this), msg.sender, amount);
        } else {
            carbon.transferFromMarket(address(this), msg.sender, amount);
        }
        totalVolume += cost;
        if (fee > 0) {
            if (!paymentToken.transferFrom(msg.sender, address(this), fee)) revert TransferFailed();
            if (!paymentToken.approve(address(treasury), fee)) revert TransferFailed();
            treasury.receiveFees(fee);
        }
        emit OrderFilled(orderId, msg.sender, amount, cost);
    }

    function setFee(uint256 bps) external onlyRole(OPERATOR_ROLE) {
        if (bps > 1000) revert ZeroAmount();
        feeBps = bps;
        emit FeeSet(bps);
    }
}
