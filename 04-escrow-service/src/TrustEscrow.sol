// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "./Ownable.sol";
import {ReentrancyGuard} from "./ReentrancyGuard.sol";

/// @title TrustEscrow
/// @notice An escrow platform written from scratch: a buyer locks ETH for a seller, the seller
///         releases it on delivery, the buyer can cancel for a refund, and a neutral arbiter
///         resolves disputes with an arbitrary split. The platform takes a fee (basis points)
///         on every completed deal.
/// @dev Funds live in this single contract; fees are accounted in `accruedFees` and withdrawn
///      by the owner (pull pattern), so the ETH never leaves without a matching accounting entry.
contract TrustEscrow is Ownable, ReentrancyGuard {
    /// @notice Lifecycle of a deal.
    enum DealState {
        Active,
        Released,
        Refunded,
        Disputed,
        Resolved
    }

    /// @notice One escrowed trade.
    struct Deal {
        address buyer;
        address seller;
        address arbiter;
        uint256 amount;
        uint256 feeBps; // platform fee FROZEN at open time — later fee changes never touch open deals
        DealState state;
    }

    /// @notice Platform fee in basis points (e.g. 50 = 0.5%), charged on release/resolve.
    ///         Applies to NEW deals only — each deal freezes its own fee at creation.
    uint256 public feeBps;

    /// @notice Hard cap on the platform fee.
    uint256 public constant MAX_FEE_BPS = 1000;

    /// @notice Total fees credited to the platform, awaiting owner withdrawal.
    uint256 public accruedFees;

    /// @notice Number of deals opened (also the next deal id).
    uint256 public dealCount;

    /// @notice Deals by id.
    mapping(uint256 => Deal) public deals;

    event DealOpened(
        uint256 indexed dealId, address indexed buyer, address indexed seller, address arbiter, uint256 amount
    );
    event DealReleased(uint256 indexed dealId, address indexed seller, uint256 amount);
    event DealRefunded(uint256 indexed dealId, address indexed buyer, uint256 amount);
    event DisputeRaised(uint256 indexed dealId, address indexed by);
    event DisputeResolved(
        uint256 indexed dealId, address indexed arbiter, uint256 buyerAmount, uint256 sellerAmount
    );
    event FeeCredited(uint256 amount);
    event FeesWithdrawn(address indexed to, uint256 amount);
    event FeeBpsUpdated(uint256 oldBps, uint256 newBps);

    error ZeroDeposit();
    error InvalidParties();
    error NotBuyer();
    error NotSeller();
    error NotArbiter();
    error NotParty();
    error NotActive(uint256 dealId);
    error NotDisputed(uint256 dealId);
    error InvalidSplit(uint256 buyerAmount, uint256 maxBuyerAmount);
    error FeeTooHigh(uint256 bps, uint256 max);
    error EthTransferFailed();

    /// @param feeBps_ Initial platform fee in basis points.
    /// @param initialOwner Address allowed to change the fee and withdraw accrued fees.
    constructor(uint256 feeBps_, address initialOwner) Ownable(initialOwner) {
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh(feeBps_, MAX_FEE_BPS);
        feeBps = feeBps_;
    }

    /* ==================== DEAL LIFECYCLE ==================== */

    /// @notice Buyer opens a deal by depositing ETH for `seller`, with `arbiter` empowered
    ///         to settle disputes. All three parties must be distinct, non-zero addresses.
    /// @return dealId The id of the new deal.
    function openDeal(address seller, address arbiter) external payable returns (uint256 dealId) {
        if (msg.value == 0) revert ZeroDeposit();
        if (seller == address(0) || arbiter == address(0)) revert InvalidParties();
        if (seller == msg.sender || arbiter == msg.sender || arbiter == seller) revert InvalidParties();

        dealId = dealCount++;
        deals[dealId] = Deal({
            buyer: msg.sender,
            seller: seller,
            arbiter: arbiter,
            amount: msg.value,
            feeBps: feeBps, // frozen: later platform fee changes never touch this deal
            state: DealState.Active
        });
        emit DealOpened(dealId, msg.sender, seller, arbiter, msg.value);
    }

    /// @notice Seller releases the funds after delivering — pays platform fee, keeps the rest.
    function release(uint256 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (msg.sender != d.seller) revert NotSeller();
        if (d.state != DealState.Active) revert NotActive(dealId);

        d.state = DealState.Released;
        uint256 fee = (d.amount * d.feeBps) / 10_000;
        uint256 payout = d.amount - fee;

        if (fee > 0) {
            accruedFees += fee;
            emit FeeCredited(fee);
        }
        (bool ok,) = d.seller.call{value: payout}("");
        if (!ok) revert EthTransferFailed();
        emit DealReleased(dealId, msg.sender, payout);
    }

    /// @notice Buyer cancels an active deal and gets the full deposit back (no fee).
    function refund(uint256 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (msg.sender != d.buyer) revert NotBuyer();
        if (d.state != DealState.Active) revert NotActive(dealId);

        d.state = DealState.Refunded;
        (bool ok,) = d.buyer.call{value: d.amount}("");
        if (!ok) revert EthTransferFailed();
        emit DealRefunded(dealId, msg.sender, d.amount);
    }

    /// @notice Buyer or seller raises a dispute; the deal is frozen until the arbiter resolves.
    function dispute(uint256 dealId) external {
        Deal storage d = deals[dealId];
        if (msg.sender != d.buyer && msg.sender != d.seller) revert NotParty();
        if (d.state != DealState.Active) revert NotActive(dealId);

        d.state = DealState.Disputed;
        emit DisputeRaised(dealId, msg.sender);
    }

    /// @notice Arbiter settles a dispute: buyer receives `buyerAmount`, the platform takes its
    ///         fee, and the seller receives the remainder.
    /// @param buyerAmount What the buyer gets back. Capped at `amount - fee`.
    function resolve(uint256 dealId, uint256 buyerAmount) external nonReentrant {
        Deal storage d = deals[dealId];
        if (msg.sender != d.arbiter) revert NotArbiter();
        if (d.state != DealState.Disputed) revert NotDisputed(dealId);

        uint256 fee = (d.amount * d.feeBps) / 10_000;
        if (buyerAmount > d.amount - fee) revert InvalidSplit(buyerAmount, d.amount - fee);
        uint256 sellerAmount = d.amount - fee - buyerAmount;

        d.state = DealState.Resolved;
        if (fee > 0) {
            accruedFees += fee;
            emit FeeCredited(fee);
        }
        if (buyerAmount > 0) {
            (bool okBuyer,) = d.buyer.call{value: buyerAmount}("");
            if (!okBuyer) revert EthTransferFailed();
        }
        if (sellerAmount > 0) {
            (bool okSeller,) = d.seller.call{value: sellerAmount}("");
            if (!okSeller) revert EthTransferFailed();
        }
        emit DisputeResolved(dealId, msg.sender, buyerAmount, sellerAmount);
    }

    /* ==================== PLATFORM ==================== */

    /// @notice Changes the platform fee for future deals. Owner only, capped.
    function setFeeBps(uint256 newBps) external onlyOwner {
        if (newBps > MAX_FEE_BPS) revert FeeTooHigh(newBps, MAX_FEE_BPS);
        emit FeeBpsUpdated(feeBps, newBps);
        feeBps = newBps;
    }

    /// @notice Owner withdraws accrued platform fees. The fee ETH sits in this contract
    ///         (deal payouts excluded it), so the balance always covers `accruedFees`.
    function withdrawFees(address payable to) external onlyOwner {
        uint256 amount = accruedFees;
        accruedFees = 0;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
        emit FeesWithdrawn(to, amount);
    }
}
