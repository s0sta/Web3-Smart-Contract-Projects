// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RahalaStable} from "./RahalaStable.sol";
import {AccessControl} from "./AccessControl.sol";
import {Checkpoints} from "./lib/Checkpoints.sol";

/// @title RahalaAccounts
/// @notice The participant ledger: the issuer mints settlement currency into
///         accounts against external deposits and burns it on redemption.
///         Balances are checkpointed for governance and accounting.
contract RahalaAccounts is AccessControl {
    using Checkpoints for Checkpoints.Checkpoint[];

    /// @notice The issuer mints and burns on deposit/withdraw.
    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER");

    RahalaStable public immutable settlement;

    mapping(address participant => uint256) public balanceOf;
    mapping(address participant => Checkpoints.Checkpoint[]) private _history;

    uint256 public totalDeposited;
    uint256 public totalWithdrawn;

    event Deposited(address indexed participant, uint256 amount);
    event Withdrawn(address indexed participant, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientBalance(uint256 balance, uint256 amount);

    constructor(RahalaStable settlement_) {
        if (address(settlement_) == address(0)) revert ZeroAddress();
        settlement = settlement_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ISSUER_ROLE, msg.sender);
    }

    /// @notice The issuer credits the participant (fiat received off-chain).
    function credit(address participant, uint256 amount) external onlyRole(ISSUER_ROLE) {
        if (participant == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        settlement.mint(participant, amount);
        balanceOf[participant] += amount;
        totalDeposited += amount;
        _history[participant].write(_history[participant].latest(), balanceOf[participant]);
        emit Deposited(participant, amount);
    }

    /// @notice The issuer debits the participant (fiat paid out off-chain).
    function debit(address participant, uint256 amount) external onlyRole(ISSUER_ROLE) {
        if (participant == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        uint256 bal = balanceOf[participant];
        if (bal < amount) revert InsufficientBalance(bal, amount);
        settlement.burn(participant, amount);
        balanceOf[participant] = bal - amount;
        totalWithdrawn += amount;
        _history[participant].write(_history[participant].latest(), balanceOf[participant]);
        emit Withdrawn(participant, amount);
    }

    function getPastBalance(address participant, uint256 blockNumber) external view returns (uint256) {
        return _history[participant].lookup(blockNumber);
    }
}
