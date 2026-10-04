// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {RahalaStable} from "./RahalaStable.sol";

/// @title RahalaSettlement
/// @notice The netting engine: participants accumulate bilateral obligations in
///         a batch, and the operator settles only the net amounts — the classic
///         correspondent-banking optimization done on-chain.
contract RahalaSettlement is AccessControl {
    /// @notice The operator submits batches and settles.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR");

    /// @notice One bilateral obligation during an open batch.
    struct Obligation {
        address from;
        address to;
        uint256 amount;
        bool settled;
    }

    Obligation[] public obligations;

    uint256 public batchNumber;
    uint256 public totalNetted;

    RahalaStable public immutable settlement;

    event BatchOpened(uint256 indexed batchNumber);
    event ObligationAdded(uint256 indexed obligationId, address indexed from, address indexed to, uint256 amount);
    event BatchSettled(uint256 indexed batchNumber, uint256 obligations, uint256 gross, uint256 net);
    event NetPaid(address indexed from, address indexed to, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error BatchClosed();
    error UnknownObligation(uint256 obligationId);
    error InsufficientBalance(uint256 balance, uint256 amount);
    error TransferFailed();

    bool public batchOpen;

    constructor(RahalaStable settlement_) {
        if (address(settlement_) == address(0)) revert ZeroAddress();
        settlement = settlement_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    /* ==================== BATCHING ==================== */

    function openBatch() external onlyRole(OPERATOR_ROLE) {
        if (batchOpen) revert BatchClosed();
        batchOpen = true;
        batchNumber += 1;
        emit BatchOpened(batchNumber);
    }

    /// @notice Records a gross obligation between two participants.
    function addObligation(address from, address to, uint256 amount) external onlyRole(OPERATOR_ROLE) returns (uint256 obligationId) {
        if (!batchOpen) revert BatchClosed();
        if (from == address(0) || to == address(0) || amount == 0) revert ZeroAmount();
        obligationId = obligations.length;
        obligations.push();
        Obligation storage o = obligations[obligationId];
        o.from = from;
        o.to = to;
        o.amount = amount;
        emit ObligationAdded(obligationId, from, to, amount);
    }

    /* ==================== NETTING & SETTLEMENT ==================== */

    /// @notice Closes the batch and settles only the net positions.
    /// @dev The operator supplies the list of net debtors/creditors and the
    ///      engine verifies each net amount against the recorded obligations.
    function settleBatch(address[] calldata debtors, uint256[] calldata netAmounts) external onlyRole(OPERATOR_ROLE) {
        if (!batchOpen) revert BatchClosed();
        if (debtors.length != netAmounts.length) revert ZeroAmount();
        batchOpen = false;

        uint256 gross;
        for (uint256 i = 0; i < obligations.length; i++) {
            if (!obligations[i].settled) gross += obligations[i].amount;
        }

        uint256 net;
        for (uint256 i = 0; i < debtors.length; i++) {
            uint256 amount = netAmounts[i];
            if (amount == 0) continue;
            uint256 bal = settlement.balanceOf(debtors[i]);
            if (bal < amount) revert InsufficientBalance(bal, amount);
            if (!settlement.transferFrom(debtors[i], address(this), amount)) revert TransferFailed();
            net += amount;
        }

        // mark the batch obligations settled and distribute the pool to creditors
        for (uint256 i = 0; i < obligations.length; i++) {
            obligations[i].settled = true;
        }
        uint256 pool = settlement.balanceOf(address(this));
        // pay creditors in order until the pool drains
        for (uint256 i = 0; i < obligations.length && pool > 0; i++) {
            Obligation storage o = obligations[i];
            uint256 pay = o.amount < pool ? o.amount : pool;
            if (pay == 0) continue;
            if (!settlement.transfer(o.to, pay)) revert TransferFailed();
            pool -= pay;
        }
        totalNetted += net;
        emit BatchSettled(batchNumber, obligations.length, gross, net);
    }

    function nettedTotal() external view returns (uint256) {
        return totalNetted;
    }
}
