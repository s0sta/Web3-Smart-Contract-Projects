// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "./ReentrancyGuard.sol";

/// @title MultiSigWallet
/// @notice A Gnosis-Safe-style multi-signature wallet implemented from scratch: a group of
///         owners manages a shared treasury, and no ETH (or arbitrary call) can leave it
///         until `threshold` owners confirm the transaction.
/// @dev Design follows the classic Gnosis MultiSigWallet (2017) pattern, still the mental
///      model behind modern Safes: submit → confirm → execute, with confirmations preserved
///      when execution fails so a flaky target can be retried.
contract MultiSigWallet is ReentrancyGuard {
    /// @notice A proposed outgoing operation.
    struct Transaction {
        address destination;
        uint256 value;
        bytes data;
        bool executed;
    }

    /// @notice The owners, in signing order.
    address[] public owners;

    /// @notice Quick membership lookup.
    mapping(address => bool) public isOwner;

    /// @notice Number of owner confirmations required to execute a transaction.
    uint256 public threshold;

    /// @notice All submitted transactions.
    Transaction[] public transactions;

    /// @notice Which owners confirmed which transaction.
    mapping(uint256 => mapping(address => bool)) public confirmations;

    /// @notice Running confirmation count per transaction.
    mapping(uint256 => uint256) public confirmationCounts;

    event Deposit(address indexed sender, uint256 value);
    event Submission(uint256 indexed txId);
    event Confirmation(address indexed sender, uint256 indexed txId);
    event Revocation(address indexed sender, uint256 indexed txId);
    event Execution(uint256 indexed txId);
    event ExecutionFailure(uint256 indexed txId);
    event ThresholdChanged(uint256 oldThreshold, uint256 newThreshold);

    error NoOwners();
    error InvalidOwner(address owner);
    error InvalidThreshold(uint256 threshold, uint256 ownerCount);
    error NotOwner(address caller);
    error TxDoesNotExist(uint256 txId);
    error AlreadyConfirmed(uint256 txId, address owner);
    error NotConfirmed(uint256 txId, address owner);
    error AlreadyExecuted(uint256 txId);
    error NotEnoughConfirmations(uint256 txId, uint256 confirmations, uint256 threshold);

    modifier onlyOwner() {
        if (!isOwner[msg.sender]) revert NotOwner(msg.sender);
        _;
    }

    /// @notice Plain ETH transfers to the wallet are accepted as deposits.
    receive() external payable {
        emit Deposit(msg.sender, msg.value);
    }

    /// @param owners_ Initial owner set. No duplicates, no zero address.
    /// @param threshold_ Confirmations needed to execute. Must be ≥ 1 and ≤ owners_.length.
    constructor(address[] memory owners_, uint256 threshold_) {
        if (owners_.length == 0) revert NoOwners();
        if (threshold_ == 0 || threshold_ > owners_.length) {
            revert InvalidThreshold(threshold_, owners_.length);
        }
        for (uint256 i = 0; i < owners_.length; i++) {
            address owner = owners_[i];
            if (owner == address(0) || isOwner[owner]) revert InvalidOwner(owner);
            isOwner[owner] = true;
            owners.push(owner);
        }
        threshold = threshold_;
    }

    /* ==================== TRANSACTION LIFECYCLE ==================== */

    /// @notice Proposes an outgoing transaction (ETH, tokens via calldata, or any call).
    /// @return txId The new transaction's id (index in `transactions`).
    function submitTransaction(address destination, uint256 value, bytes calldata data)
        external
        onlyOwner
        returns (uint256 txId)
    {
        txId = transactions.length;
        transactions.push(Transaction(destination, value, data, false));
        emit Submission(txId);
    }

    /// @notice Confirms a pending transaction. Caller must be an owner.
    function confirmTransaction(uint256 txId) external onlyOwner {
        if (txId >= transactions.length) revert TxDoesNotExist(txId);
        if (confirmations[txId][msg.sender]) revert AlreadyConfirmed(txId, msg.sender);
        confirmations[txId][msg.sender] = true;
        confirmationCounts[txId]++;
        emit Confirmation(msg.sender, txId);
    }

    /// @notice Removes the caller's confirmation from a still-pending transaction.
    function revokeConfirmation(uint256 txId) external onlyOwner {
        if (txId >= transactions.length) revert TxDoesNotExist(txId);
        if (transactions[txId].executed) revert AlreadyExecuted(txId);
        if (!confirmations[txId][msg.sender]) revert NotConfirmed(txId, msg.sender);
        confirmations[txId][msg.sender] = false;
        confirmationCounts[txId]--;
        emit Revocation(msg.sender, txId);
    }

    /// @notice Executes a transaction once `threshold` confirmations exist.
    /// @dev The `executed` flag is set *before* the external call: if the call fails, the flag
    ///      is rolled back and the transaction can be retried later (confirmations persist).
    function executeTransaction(uint256 txId) external nonReentrant onlyOwner {
        if (txId >= transactions.length) revert TxDoesNotExist(txId);
        Transaction storage t = transactions[txId];
        if (t.executed) revert AlreadyExecuted(txId);
        if (confirmationCounts[txId] < threshold) {
            revert NotEnoughConfirmations(txId, confirmationCounts[txId], threshold);
        }

        t.executed = true;
        (bool ok,) = t.destination.call{value: t.value}(t.data);
        if (!ok) {
            t.executed = false;
            emit ExecutionFailure(txId);
        } else {
            emit Execution(txId);
        }
    }

    /* ==================== CONFIGURATION ==================== */

    /// @notice Changes the confirmation threshold. Cannot be 0 or exceed the owner count.
    function changeThreshold(uint256 newThreshold) external onlyOwner {
        if (newThreshold == 0 || newThreshold > owners.length) {
            revert InvalidThreshold(newThreshold, owners.length);
        }
        emit ThresholdChanged(threshold, newThreshold);
        threshold = newThreshold;
    }

    /* ==================== VIEWS ==================== */

    function getOwners() external view returns (address[] memory) {
        return owners;
    }

    function transactionCount() external view returns (uint256) {
        return transactions.length;
    }

    function getConfirmationCount(uint256 txId) external view returns (uint256) {
        return confirmationCounts[txId];
    }

    function isConfirmed(uint256 txId, address owner) external view returns (bool) {
        return confirmations[txId][owner];
    }

    /// @notice Lists owners who have confirmed `txId`, in owner order.
    function getConfirmations(uint256 txId) external view returns (address[] memory confirmed) {
        uint256 count = confirmationCounts[txId];
        confirmed = new address[](count);
        uint256 j;
        for (uint256 i = 0; i < owners.length && j < count; i++) {
            if (confirmations[txId][owners[i]]) {
                confirmed[j] = owners[i];
                j++;
            }
        }
    }
}
