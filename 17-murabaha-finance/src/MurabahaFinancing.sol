// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";
import {AccessControl} from "./AccessControl.sol";

/// @title MurabahaFinancing
/// @notice Sharia-compliant trade finance (murabaha): the financier buys an asset
///         from the supplier at cost, sells it to the buyer at cost plus a
///         disclosed, fixed markup, and the buyer repays in installments.
///
///   · **Lifecycle** — Request → Shariah approval → supplier purchase →
///     delivery confirmation (title passes) → installments → settled/default.
///   · **No riba** — the markup is fixed and disclosed before the sale; late
///     payments incur a penalty that is routed to a CHARITY address, never to
///     the financier; no compounding anywhere.
///   · **Early settlement** — the buyer may prepay the remaining installments
///     at a discount (rebate for early settlement).
///   · **Recovery** — missed installments past a threshold put the trade into
///     default; the financier may call recovery (the guarantor is recorded).
///   · **Documentation** — the supplier invoice hash and the asset description
///     are stored on-chain for the Shariah board and auditors.
contract MurabahaFinancing is AccessControl {
    /// @notice The financier (bank): funds purchases, collects installments.
    bytes32 public constant FINANCIER_ROLE = keccak256("FINANCIER");

    /// @notice The Shariah board: approves each trade's terms.
    bytes32 public constant SHARIAH_ROLE = keccak256("SHARIAH");

    /// @notice Trade status.
    enum Status { Requested, Approved, Purchased, Delivered, Repaying, Settled, Defaulted, Rejected }

    /// @notice One financed trade.
    struct Trade {
        address buyer;
        address supplier;
        address guarantor;
        uint256 costPrice; // what the financier pays the supplier
        uint256 markup; // disclosed fixed profit
        uint256 installmentAmount; // per installment
        uint256 installments; // total installments
        uint256 paidInstallments;
        uint64 firstDue; // first installment due date
        uint64 interval; // between installments
        uint256 lateFeeCharged; // fees routed to charity
        uint256 rebateGiven; // early-settlement rebates
        bytes32 invoiceHash; // supplier invoice documentation
        string assetDescription;
        Status status;
    }

    Trade[] public trades;

    /// @notice The charity address receiving late penalties (never the financier).
    address public charity;

    /// @notice Early-settlement rebate in bps of the remaining markup.
    uint256 public settlementRebateBps;

    /// @notice Missed installments allowed before default.
    uint256 public maxMissedInstallments;

    /// @notice Late penalty per missed installment (bps of the installment).
    uint256 public latePenaltyBps;

    IERC20 public immutable paymentToken;

    bool public paused;

    event TradeRequested(uint256 indexed tradeId, address indexed buyer, address indexed supplier, uint256 costPrice, uint256 markup);
    event TradeApproved(uint256 indexed tradeId, address indexed shariah);
    event TradeRejected(uint256 indexed tradeId);
    event AssetPurchased(uint256 indexed tradeId, uint256 paid);
    event DeliveryConfirmed(uint256 indexed tradeId);
    event InstallmentPaid(uint256 indexed tradeId, uint256 amount, uint256 installment);
    event LateFeeCharged(uint256 indexed tradeId, uint256 fee, address indexed charity);
    event TradeSettled(uint256 indexed tradeId, uint256 rebate);
    event TradeDefaulted(uint256 indexed tradeId);
    event Recovered(uint256 indexed tradeId, address indexed to, uint256 amount);
    event CharitySet(address indexed charity);
    event Paused(bool paused);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownTrade(uint256 tradeId);
    error InvalidState(uint256 tradeId, Status expected, Status actual);
    error NotBuyer(uint256 tradeId);
    error NotFinancier();
    error NotShariah();
    error ProtocolPaused();
    error InvalidMarkup();
    error NoInstallmentsDue();
    error InsufficientPayment(uint256 needed, uint256 given);
    error NothingToRecover();
    error TransferFailed();

    constructor(
        IERC20 paymentToken_,
        address charity_,
        uint256 settlementRebateBps_,
        uint256 maxMissedInstallments_,
        uint256 latePenaltyBps_
    ) {
        if (address(paymentToken_) == address(0) || charity_ == address(0)) revert ZeroAddress();
        paymentToken = paymentToken_;
        charity = charity_;
        settlementRebateBps = settlementRebateBps_;
        maxMissedInstallments = maxMissedInstallments_;
        latePenaltyBps = latePenaltyBps_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(FINANCIER_ROLE, msg.sender);
        _grantRole(SHARIAH_ROLE, msg.sender);
        _grantRole(GUARDIAN_ROLE, msg.sender);
    }

    modifier whenNotPaused() {
        if (paused) revert ProtocolPaused();
        _;
    }

    /* ==================== REQUEST & APPROVAL ==================== */

    function requestTrade(
        address supplier,
        address guarantor,
        uint256 costPrice,
        uint256 markup,
        uint256 installments,
        uint64 interval,
        bytes32 invoiceHash,
        string calldata assetDescription
    ) external whenNotPaused returns (uint256 tradeId) {
        if (supplier == address(0) || guarantor == address(0)) revert ZeroAddress();
        if (costPrice == 0 || markup == 0 || installments == 0 || interval == 0) revert ZeroAmount();
        if (markup > costPrice / 2) revert InvalidMarkup(); // profit cap: 50% of cost

        tradeId = trades.length;
        trades.push();
        Trade storage t = trades[tradeId];
        t.buyer = msg.sender;
        t.supplier = supplier;
        t.guarantor = guarantor;
        t.costPrice = costPrice;
        t.markup = markup;
        t.installmentAmount = (costPrice + markup) / installments;
        t.installments = installments;
        t.firstDue = uint64(block.timestamp + 30 days);
        t.interval = interval;
        t.invoiceHash = invoiceHash;
        t.assetDescription = assetDescription;
        t.status = Status.Requested;
        emit TradeRequested(tradeId, msg.sender, supplier, costPrice, markup);
    }

    function approveTrade(uint256 tradeId) external onlyRole(SHARIAH_ROLE) {
        Trade storage t = trades[tradeId];
        if (t.costPrice == 0) revert UnknownTrade(tradeId);
        if (t.status != Status.Requested) revert InvalidState(tradeId, Status.Requested, t.status);
        t.status = Status.Approved;
        emit TradeApproved(tradeId, msg.sender);
    }

    function rejectTrade(uint256 tradeId) external onlyRole(SHARIAH_ROLE) {
        Trade storage t = trades[tradeId];
        if (t.status != Status.Requested) revert InvalidState(tradeId, Status.Requested, t.status);
        t.status = Status.Rejected;
        emit TradeRejected(tradeId);
    }

    /* ==================== PURCHASE & DELIVERY ==================== */

    /// @notice The financier pays the supplier directly (title to the financier).
    function purchaseAsset(uint256 tradeId) external onlyRole(FINANCIER_ROLE) whenNotPaused {
        Trade storage t = trades[tradeId];
        if (t.status != Status.Approved) revert InvalidState(tradeId, Status.Approved, t.status);
        if (!paymentToken.transferFrom(msg.sender, t.supplier, t.costPrice)) revert TransferFailed();
        t.status = Status.Purchased;
        emit AssetPurchased(tradeId, t.costPrice);
    }

    /// @notice The buyer confirms delivery — title passes, repayment starts.
    function confirmDelivery(uint256 tradeId) external whenNotPaused {
        Trade storage t = trades[tradeId];
        if (t.costPrice == 0) revert UnknownTrade(tradeId);
        if (msg.sender != t.buyer) revert NotBuyer(tradeId);
        if (t.status != Status.Purchased) revert InvalidState(tradeId, Status.Purchased, t.status);
        t.status = Status.Delivered;
        emit DeliveryConfirmed(tradeId);
    }

    /* ==================== REPAYMENT ==================== */

    /// @notice The buyer pays the next due installment(s).
    function payInstallment(uint256 tradeId) external whenNotPaused {
        Trade storage t = trades[tradeId];
        if (t.costPrice == 0) revert UnknownTrade(tradeId);
        if (msg.sender != t.buyer && msg.sender != t.guarantor) revert NotBuyer(tradeId);
        if (t.status != Status.Delivered && t.status != Status.Repaying) {
            revert InvalidState(tradeId, Status.Delivered, t.status);
        }

        uint256 missed = missedInstallments(tradeId);
        // late penalty → charity (the financier never earns it)
        _chargeLateFee(tradeId, t, missed);

        t.paidInstallments += 1 + missed;

        if (t.status == Status.Delivered) t.status = Status.Repaying;
        if (!paymentToken.transferFrom(msg.sender, address(this), t.installmentAmount * (1 + missed))) {
            revert TransferFailed();
        }
        emit InstallmentPaid(tradeId, t.installmentAmount * (1 + missed), t.paidInstallments);

        if (t.paidInstallments >= t.installments) {
            t.status = Status.Settled;
            emit TradeSettled(tradeId, 0);
        }
    }

    function _chargeLateFee(uint256 tradeId, Trade storage t, uint256 missed) internal {
        if (missed == 0) return;
        uint256 fee = (t.installmentAmount * latePenaltyBps * missed) / 10_000;
        t.lateFeeCharged += fee;
        if (!paymentToken.transferFrom(msg.sender, charity, fee)) revert TransferFailed();
        emit LateFeeCharged(tradeId, fee, charity);
    }

    /// @notice Early settlement: the remaining installments with a rebate on the
    ///         remaining markup (the financier forgoes part of its profit).
    function settleEarly(uint256 tradeId) external whenNotPaused {
        Trade storage t = trades[tradeId];
        if (t.costPrice == 0) revert UnknownTrade(tradeId);
        if (msg.sender != t.buyer) revert NotBuyer(tradeId);
        if (t.status != Status.Repaying) revert InvalidState(tradeId, Status.Repaying, t.status);

        uint256 remainingInstallments = t.installments - t.paidInstallments;
        if (remainingInstallments == 0) revert NoInstallmentsDue();
        uint256 remainingMarkup = (t.markup * remainingInstallments) / t.installments;
        uint256 rebate = (remainingMarkup * settlementRebateBps) / 10_000;
        uint256 due = remainingInstallments * t.installmentAmount - rebate;

        if (!paymentToken.transferFrom(msg.sender, address(this), due)) revert TransferFailed();
        t.rebateGiven += rebate;
        t.paidInstallments = t.installments;
        t.status = Status.Settled;
        emit TradeSettled(tradeId, rebate);
    }

    function missedInstallments(uint256 tradeId) public view returns (uint256) {
        Trade storage t = trades[tradeId];
        if (t.paidInstallments >= t.installments) return 0;
        uint256 dueSoFar = block.timestamp > t.firstDue
            ? (block.timestamp - t.firstDue) / t.interval + 1
            : 0;
        if (dueSoFar <= t.paidInstallments) return 0;
        return dueSoFar - t.paidInstallments;
    }

    /* ==================== DEFAULT & RECOVERY ==================== */

    /// @notice Anyone can mark a trade defaulted once it is too far behind.
    function markDefault(uint256 tradeId) external {
        Trade storage t = trades[tradeId];
        if (t.costPrice == 0) revert UnknownTrade(tradeId);
        if (t.status != Status.Repaying) revert InvalidState(tradeId, Status.Repaying, t.status);
        if (missedInstallments(tradeId) <= maxMissedInstallments) revert NoInstallmentsDue();
        t.status = Status.Defaulted;
        emit TradeDefaulted(tradeId);
    }

    /// @notice The financier recovers collected funds (partial recovery) on default.
    function recover(uint256 tradeId, address to, uint256 amount) external onlyRole(FINANCIER_ROLE) {
        Trade storage t = trades[tradeId];
        if (t.status != Status.Defaulted && t.status != Status.Settled) {
            revert InvalidState(tradeId, Status.Defaulted, t.status);
        }
        if (amount == 0) revert ZeroAmount();
        if (!paymentToken.transfer(to, amount)) revert TransferFailed();
        emit Recovered(tradeId, to, amount);
    }

    /* ==================== ADMIN & GUARDIAN ==================== */

    function setCharity(address charity_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (charity_ == address(0)) revert ZeroAddress();
        charity = charity_;
        emit CharitySet(charity_);
    }

    function setSettlementRebateBps(uint256 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > 10_000) revert ZeroAmount();
        settlementRebateBps = bps;
    }

    function setLatePenaltyBps(uint256 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > 10_000) revert ZeroAmount();
        latePenaltyBps = bps;
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        paused = true;
        emit Paused(true);
    }

    function unpause() external onlyRole(GUARDIAN_ROLE) {
        paused = false;
        emit Paused(false);
    }
}
