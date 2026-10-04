// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";
import {AccessControl} from "./AccessControl.sol";
import {SahmCollateral} from "./SahmCollateral.sol";
import {SahmCompliance} from "./SahmCompliance.sol";
import {SahmRisk} from "./SahmRisk.sol";
import {SahmTreasury} from "./SahmTreasury.sol";

/// @title SahmOrderBook
/// @notice The spot desk: a limit-order book per market matched at price–time
///         priority. Funds sit in the collateral desk's locked margin until the
///         order fills or is canceled; maker fees go to the treasury.
contract SahmOrderBook is AccessControl {
    /// @notice The operator manages fees.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR");

    /// @notice One resting order.
    struct Order {
        address maker;
        address token; // the traded asset
        bool isBid;
        uint256 price; // quote per whole token (18-decimals)
        uint256 amount; // remaining token amount
        bool active;
    }

    Order[] public orders;

    uint256 public makerFeeBps;
    uint256 public takerFeeBps;
    uint256 public totalVolume;

    SahmCollateral public immutable collateral;
    SahmCompliance public immutable compliance;
    SahmRisk public immutable risk;
    SahmTreasury public immutable treasury;
    IERC20 public immutable quoteToken;

    event OrderPlaced(uint256 indexed orderId, address indexed maker, address token, bool isBid, uint256 price, uint256 amount);
    event OrderFilled(uint256 indexed orderId, address indexed taker, uint256 amount, uint256 price);
    event OrderCanceled(uint256 indexed orderId);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownOrder(uint256 orderId);
    error OrderInactive(uint256 orderId);
    error NotMaker(uint256 orderId);
    error SelfFill(address trader);
    error LimitPrice(uint256 orderPrice, uint256 requiredPrice);
    error TransferFailed();

    constructor(
        SahmCollateral collateral_,
        SahmCompliance compliance_,
        SahmRisk risk_,
        SahmTreasury treasury_,
        IERC20 quoteToken_
    ) {
        if (address(collateral_) == address(0) || address(compliance_) == address(0) || address(risk_) == address(0) || address(treasury_) == address(0) || address(quoteToken_) == address(0)) {
            revert ZeroAddress();
        }
        collateral = collateral_;
        compliance = compliance_;
        risk = risk_;
        treasury = treasury_;
        quoteToken = quoteToken_;
        makerFeeBps = 10; // 0.1%
        takerFeeBps = 20; // 0.2%
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    /* ==================== PLACE & CANCEL ==================== */

    function placeBid(address token, uint256 price, uint256 amount) external returns (uint256 orderId) {
        return _place(token, price, amount, true);
    }

    function placeAsk(address token, uint256 price, uint256 amount) external returns (uint256 orderId) {
        return _place(token, price, amount, false);
    }

    function _place(address token, uint256 price, uint256 amount, bool isBid) internal returns (uint256 orderId) {
        if (token == address(0) || price == 0 || amount == 0) revert ZeroAmount();
        if (!compliance.canTrade(msg.sender)) revert();

        orderId = orders.length;
        orders.push();
        Order storage o = orders[orderId];
        o.maker = msg.sender;
        o.token = token;
        o.isBid = isBid;
        o.price = price;
        o.amount = amount;
        o.active = true;

        // escrow: a bid locks the quote cost; an ask locks the tokens
        if (isBid) {
            uint256 cost = (amount * price) / 1e18;
            collateral.lockMargin(msg.sender, cost);
        } else {
            if (!IERC20(token).transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        }
        emit OrderPlaced(orderId, msg.sender, token, isBid, price, amount);
    }

    function cancelOrder(uint256 orderId) external {
        Order storage o = orders[orderId];
        if (o.maker == address(0)) revert UnknownOrder(orderId);
        if (msg.sender != o.maker) revert NotMaker(orderId);
        if (!o.active) revert OrderInactive(orderId);
        o.active = false;
        if (o.isBid) {
            uint256 cost = (o.amount * o.price) / 1e18;
            collateral.unlockMargin(o.maker, cost);
        } else {
            if (!IERC20(o.token).transfer(o.maker, o.amount)) revert TransferFailed();
        }
        emit OrderCanceled(orderId);
    }

    /* ==================== MATCHING ==================== */

    /// @notice Fills a resting ask against a market taker (taker buys the token).
    function buy(uint256 orderId, uint256 amount) external {
        Order storage o = orders[orderId];
        if (o.maker == address(0)) revert UnknownOrder(orderId);
        if (msg.sender == o.maker) revert SelfFill(msg.sender);
        if (!o.active) revert OrderInactive(orderId);
        if (o.isBid) revert LimitPrice(0, 1);
        if (amount > o.amount) revert LimitPrice(o.amount, amount);

        uint256 cost = (amount * o.price) / 1e18;
        uint256 fee = (cost * takerFeeBps) / 10_000;
        o.amount -= amount;
        if (o.amount == 0) o.active = false;

        // taker pays cost+fee; the maker receives cost minus the maker fee
        uint256 makerFee = (cost * makerFeeBps) / 10_000;
        if (!quoteToken.transferFrom(msg.sender, address(this), cost + fee)) revert TransferFailed();
        if (!IERC20(o.token).transfer(msg.sender, amount)) revert TransferFailed();
        if (!quoteToken.transfer(o.maker, cost - makerFee)) revert TransferFailed();

        _postFill(o.token, cost, fee, makerFee);
        emit OrderFilled(orderId, msg.sender, amount, o.price);
    }

    /// @notice Fills a resting bid against a market taker (taker sells the token).
    function sell(uint256 orderId, uint256 amount) external {
        Order storage o = orders[orderId];
        if (o.maker == address(0)) revert UnknownOrder(orderId);
        if (msg.sender == o.maker) revert SelfFill(msg.sender);
        if (!o.active) revert OrderInactive(orderId);
        if (!o.isBid) revert LimitPrice(0, 1);
        if (amount > o.amount) revert LimitPrice(o.amount, amount);

        uint256 cost = (amount * o.price) / 1e18;
        uint256 fee = (cost * takerFeeBps) / 10_000;
        uint256 makerFee = (cost * makerFeeBps) / 10_000;
        o.amount -= amount;
        if (o.amount == 0) o.active = false;

        // taker delivers the tokens; the maker's escrow pays the taker
        if (!IERC20(o.token).transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        collateral.payOut(msg.sender, cost - fee);
        collateral.payOut(o.maker, makerFee);
        // the fee pool is drawn from the maker's collateral and forwarded below
        collateral.payOut(address(this), fee + makerFee);
        // release the maker's remaining escrow
        collateral.unlockMargin(o.maker, cost);

        _postFill(o.token, cost, fee, makerFee);
        emit OrderFilled(orderId, msg.sender, amount, o.price);
    }

    function _postFill(address token, uint256 cost, uint256 takerFee, uint256 makerFee) internal {
        totalVolume += cost;
        compliance.recordVolume(msg.sender, cost);
        risk.recordVolume(token, cost);
        uint256 totalFee = takerFee + makerFee;
        if (totalFee > 0) {
            if (!quoteToken.approve(address(treasury), totalFee)) revert TransferFailed();
            treasury.receiveFees(totalFee);
        }
    }

    /* ==================== ADMIN ==================== */

    function setFees(uint256 makerBps, uint256 takerBps) external onlyRole(OPERATOR_ROLE) {
        if (makerBps > 500 || takerBps > 500) revert ZeroAmount();
        makerFeeBps = makerBps;
        takerFeeBps = takerBps;
    }
}
