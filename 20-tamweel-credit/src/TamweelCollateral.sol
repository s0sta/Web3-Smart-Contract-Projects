// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";
import {AccessControl} from "./AccessControl.sol";

/// @title TamweelCollateral
/// @notice The collateral desk: which assets are accepted (with per-asset price
///         oracles handled by the markets), and the liquidation auction house —
///         seized collateral is auctioned Dutch-style: the price starts high and
///         decays linearly until a bidder claims it at the current price.
contract TamweelCollateral is AccessControl {
    /// @notice The markets contract starts auctions.
    bytes32 public constant MARKETS_ROLE = keccak256("MARKETS");

    /// @notice One running auction.
    struct Auction {
        uint256 marketId;
        address liquidatedUser;
        address beneficiary; // the liquidator who repaid the debt
        uint256 collateralAmount;
        uint256 startPrice; // per token
        uint256 floorPrice; // per token
        uint64 startTime;
        uint64 duration;
        bool settled;
    }

    Auction[] public auctions;

    mapping(address collateralToken => bool) public accepted;

    IERC20 public immutable paymentToken;

    event CollateralAccepted(address indexed token, bool accepted);
    event AuctionStarted(uint256 indexed auctionId, uint256 marketId, uint256 amount, uint256 startPrice);
    event AuctionBid(uint256 indexed auctionId, address indexed bidder, uint256 price, uint256 cost);
    event AuctionSettled(uint256 indexed auctionId, uint256 proceeds);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownAuction(uint256 auctionId);
    error AlreadySettled(uint256 auctionId);
    error NotAccepted(address token);
    error TransferFailed();

    constructor(IERC20 paymentToken_) {
        if (address(paymentToken_) == address(0)) revert ZeroAddress();
        paymentToken = paymentToken_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MARKETS_ROLE, msg.sender);
    }

    function setAccepted(address token, bool accepted_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        accepted[token] = accepted_;
        emit CollateralAccepted(token, accepted_);
    }

    /// @notice The markets start a Dutch auction for seized collateral.
    function startAuction(
        uint256 marketId,
        address liquidatedUser,
        address beneficiary,
        uint256 collateralAmount,
        uint256 debtToCover
    ) external onlyRole(MARKETS_ROLE) returns (uint256 auctionId) {
        if (collateralAmount == 0 || debtToCover == 0) revert ZeroAmount();
        auctionId = auctions.length;
        auctions.push();
        Auction storage a = auctions[auctionId];
        a.marketId = marketId;
        a.liquidatedUser = liquidatedUser;
        a.beneficiary = beneficiary;
        a.collateralAmount = collateralAmount;
        // start at ~2x the debt per token, decay to ~0.5x
        a.startPrice = (debtToCover * 2 * 1e18) / collateralAmount;
        a.floorPrice = (debtToCover * 5) / (collateralAmount * 10);
        a.startTime = uint64(block.timestamp);
        a.duration = 1 days;
        emit AuctionStarted(auctionId, marketId, collateralAmount, a.startPrice);
    }

    /// @notice The current Dutch-auction price (linear decay).
    function currentPrice(uint256 auctionId) public view returns (uint256) {
        Auction storage a = auctions[auctionId];
        if (a.startPrice == 0) revert UnknownAuction(auctionId);
        uint256 elapsed = block.timestamp - a.startTime;
        if (elapsed >= a.duration) return a.floorPrice;
        uint256 range = a.startPrice - a.floorPrice;
        return a.startPrice - (range * elapsed) / a.duration;
    }

    /// @notice Bids at the current price; the collateral goes to the bidder and the
    ///         proceeds go to the beneficiary (the liquidator).
    function bid(uint256 auctionId) external returns (uint256 cost) {
        Auction storage a = auctions[auctionId];
        if (a.startPrice == 0) revert UnknownAuction(auctionId);
        if (a.settled) revert AlreadySettled(auctionId);
        uint256 price = currentPrice(auctionId);
        cost = (a.collateralAmount * price) / 1e18;
        if (cost == 0) revert ZeroAmount();

        a.settled = true;
        if (!paymentToken.transferFrom(msg.sender, a.beneficiary, cost)) revert TransferFailed();
        emit AuctionBid(auctionId, msg.sender, price, cost);
        emit AuctionSettled(auctionId, cost);
    }
}
