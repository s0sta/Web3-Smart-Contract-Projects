// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {RahalaStable} from "./RahalaStable.sol";
import {RahalaCompliance} from "./RahalaCompliance.sol";

/// @title RahalaInvoices
/// @notice Trade finance: sellers register invoices, financiers buy them at a
///         disclosed discount (factoring), and payers settle them. Settlement
///         releases the face value to the factor who advanced against it.
contract RahalaInvoices is AccessControl {
    /// @notice The operator adjusts parameters.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR");

    /// @notice Invoice states.
    enum Status { Open, Factored, Settled, Canceled }

    /// @notice One invoice.
    struct Invoice {
        address seller;
        address payer;
        uint256 faceValue;
        uint256 factoredAmount; // what the financier advanced
        address financier;
        uint64 dueDate;
        uint64 region;
        string description;
        Status status;
    }

    Invoice[] public invoices;

    /// @notice Minimum discount (bps) a financier must offer the seller.
    uint256 public minDiscountBps;

    RahalaStable public immutable settlement;
    RahalaCompliance public immutable compliance;

    event InvoiceRegistered(uint256 indexed invoiceId, address indexed seller, address indexed payer, uint256 faceValue);
    event InvoiceFactored(uint256 indexed invoiceId, address indexed financier, uint256 advance);
    event InvoiceSettled(uint256 indexed invoiceId, uint256 paid);
    event InvoiceCanceled(uint256 indexed invoiceId);
    event DiscountSet(uint256 bps);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownInvoice(uint256 invoiceId);
    error InvalidState(uint256 invoiceId, Status expected, Status actual);
    error NotSellerOrFinancier(uint256 invoiceId);
    error DiscountTooLow(uint256 offered, uint256 minimum);
    error TransferFailed();

    constructor(RahalaStable settlement_, RahalaCompliance compliance_) {
        if (address(settlement_) == address(0) || address(compliance_) == address(0)) revert ZeroAddress();
        settlement = settlement_;
        compliance = compliance_;
        minDiscountBps = 300; // 3%
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    /* ==================== REGISTRATION ==================== */

    function registerInvoice(
        address payer,
        uint256 faceValue,
        uint64 dueDate,
        uint64 region,
        string calldata description
    ) external returns (uint256 invoiceId) {
        if (payer == address(0) || faceValue == 0) revert ZeroAmount();
        compliance.validateTransfer(payer, msg.sender, region, faceValue, bytes32(uint256(1)));

        invoiceId = invoices.length;
        invoices.push();
        Invoice storage inv = invoices[invoiceId];
        inv.seller = msg.sender;
        inv.payer = payer;
        inv.faceValue = faceValue;
        inv.dueDate = dueDate;
        inv.region = region;
        inv.description = description;
        inv.status = Status.Open;
        emit InvoiceRegistered(invoiceId, msg.sender, payer, faceValue);
    }

    /* ==================== FACTORING ==================== */

    /// @notice A financier buys the invoice at a discount: the seller receives
    ///         the advance immediately; the financier collects the face value
    ///         when the payer settles.
    function factor(uint256 invoiceId) external {
        Invoice storage inv = invoices[invoiceId];
        if (inv.seller == address(0)) revert UnknownInvoice(invoiceId);
        if (inv.status != Status.Open) revert InvalidState(invoiceId, Status.Open, inv.status);

        uint256 discount = (inv.faceValue * minDiscountBps) / 10_000;
        uint256 advance = inv.faceValue - discount;
        if (advance < inv.faceValue * 9 / 10) revert DiscountTooLow(minDiscountBps, 10_000);

        inv.financier = msg.sender;
        inv.factoredAmount = advance;
        inv.status = Status.Factored;

        if (!settlement.transferFrom(msg.sender, inv.seller, advance)) revert TransferFailed();
        emit InvoiceFactored(invoiceId, msg.sender, advance);
    }

    /// @notice The payer settles the invoice; the face value goes to the factor.
    function settle(uint256 invoiceId) external {
        Invoice storage inv = invoices[invoiceId];
        if (inv.seller == address(0)) revert UnknownInvoice(invoiceId);
        if (msg.sender != inv.payer) revert NotSellerOrFinancier(invoiceId);
        if (inv.status != Status.Factored) revert InvalidState(invoiceId, Status.Factored, inv.status);

        inv.status = Status.Settled;
        address payee = inv.financier;
        if (!settlement.transferFrom(msg.sender, payee, inv.faceValue)) revert TransferFailed();
        emit InvoiceSettled(invoiceId, inv.faceValue);
    }

    /// @notice The seller cancels an open (unfactored) invoice.
    function cancel(uint256 invoiceId) external {
        Invoice storage inv = invoices[invoiceId];
        if (msg.sender != inv.seller) revert NotSellerOrFinancier(invoiceId);
        if (inv.status != Status.Open) revert InvalidState(invoiceId, Status.Open, inv.status);
        inv.status = Status.Canceled;
        emit InvoiceCanceled(invoiceId);
    }

    function setMinDiscount(uint256 bps) external onlyRole(OPERATOR_ROLE) {
        if (bps > 3000) revert ZeroAmount();
        minDiscountBps = bps;
        emit DiscountSet(bps);
    }
}
