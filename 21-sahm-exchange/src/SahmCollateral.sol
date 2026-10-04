// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";
import {AccessControl} from "./AccessControl.sol";
import {Checkpoints} from "./lib/Checkpoints.sol";

/// @title SahmCollateral
/// @notice The margin custody desk: traders deposit the quote stable as margin,
///         withdraw when it is not backing an open position, and the margin engine
///         locks/unlocks margin for positions. Balances are checkpointed for
///         governance and accounting.
contract SahmCollateral is AccessControl {
    using Checkpoints for Checkpoints.Checkpoint[];

    /// @notice The margin engine locks and unlocks margin.
    bytes32 public constant MARGIN_ROLE = keccak256("MARGIN");

    /// @notice The order book escrows margin for limit orders.
    bytes32 public constant ORDERBOOK_ROLE = keccak256("ORDERBOOK");

    IERC20 public immutable quoteToken;

    mapping(address trader => uint256) public balanceOf;
    mapping(address trader => uint256) public lockedMargin;

    mapping(address trader => Checkpoints.Checkpoint[]) private _balanceHistory;

    uint256 public totalDeposited;

    event Deposited(address indexed trader, uint256 amount);
    event Withdrawn(address indexed trader, uint256 amount);
    event MarginLocked(address indexed trader, uint256 amount);
    event MarginUnlocked(address indexed trader, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientBalance(uint256 balance, uint256 amount);
    error InsufficientFreeMargin(uint256 free, uint256 needed);
    error TransferFailed();

    constructor(IERC20 quoteToken_) {
        if (address(quoteToken_) == address(0)) revert ZeroAddress();
        quoteToken = quoteToken_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MARGIN_ROLE, msg.sender);
        _grantRole(ORDERBOOK_ROLE, msg.sender);
    }

    /* ==================== DEPOSITS & WITHDRAWALS ==================== */

    function deposit(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (!quoteToken.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        balanceOf[msg.sender] += amount;
        totalDeposited += amount;
        _balanceHistory[msg.sender].write(_balanceHistory[msg.sender].latest(), balanceOf[msg.sender]);
        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        uint256 free = freeMargin(msg.sender);
        if (amount > free) revert InsufficientFreeMargin(free, amount);
        balanceOf[msg.sender] -= amount;
        totalDeposited -= amount;
        _balanceHistory[msg.sender].write(_balanceHistory[msg.sender].latest(), balanceOf[msg.sender]);
        if (!quoteToken.transfer(msg.sender, amount)) revert TransferFailed();
        emit Withdrawn(msg.sender, amount);
    }

    function freeMargin(address trader) public view returns (uint256) {
        uint256 bal = balanceOf[trader];
        uint256 locked = lockedMargin[trader];
        return bal > locked ? bal - locked : 0;
    }

    /* ==================== MARGIN LOCKING ==================== */

    function lockMargin(address trader, uint256 amount) external {
        if (!hasRole(MARGIN_ROLE, msg.sender) && !hasRole(ORDERBOOK_ROLE, msg.sender)) revert();
        uint256 free = freeMargin(trader);
        if (amount > free) revert InsufficientFreeMargin(free, amount);
        lockedMargin[trader] += amount;
        emit MarginLocked(trader, amount);
    }

    function unlockMargin(address trader, uint256 amount) external {
        if (!hasRole(MARGIN_ROLE, msg.sender) && !hasRole(ORDERBOOK_ROLE, msg.sender)) revert();
        if (amount > lockedMargin[trader]) revert InsufficientFreeMargin(lockedMargin[trader], amount);
        lockedMargin[trader] -= amount;
        emit MarginUnlocked(trader, amount);
    }

    function getPastBalance(address trader, uint256 blockNumber) external view returns (uint256) {
        return _balanceHistory[trader].lookup(blockNumber);
    }

    /// @notice The margin engine pays a winning trader from the pool.
    function payOut(address to, uint256 amount) external {
        if (!hasRole(MARGIN_ROLE, msg.sender) && !hasRole(ORDERBOOK_ROLE, msg.sender)) revert();
        if (amount == 0) revert ZeroAmount();
        if (!quoteToken.transfer(to, amount)) revert TransferFailed();
    }

    /// @notice The margin engine burns a losing trader's margin (socialized to
    ///         the pool that funded the winning side).
    function burnMargin(address trader, uint256 amount) external {
        if (!hasRole(MARGIN_ROLE, msg.sender) && !hasRole(ORDERBOOK_ROLE, msg.sender)) revert();
        uint256 bal = balanceOf[trader];
        uint256 burn = amount > bal ? bal : amount;
        balanceOf[trader] = bal - burn;
        totalDeposited -= burn;
        _balanceHistory[trader].write(_balanceHistory[trader].latest(), balanceOf[trader]);
        emit Withdrawn(trader, burn);
    }
}
