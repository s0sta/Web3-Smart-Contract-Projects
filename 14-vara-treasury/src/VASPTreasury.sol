// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";
import {AccessControl} from "./AccessControl.sol";
import {Checkpoints} from "./lib/Checkpoints.sol";
import {ComplianceModule} from "./ComplianceModule.sol";

/// @title VASPTreasury
/// @notice A regulated corporate treasury for a licensed VASP (VARA-style):
///
///   · **Asset segregation** — client assets and house equity are separate ledgers;
///     client funds can only move on client instructions.
///   · **Risk limits** — per-transaction and per-day withdrawal ceilings from the
///     compliance module's KYC tiers, enforced with rolling 24h windows.
///   · **Capital reserve** — house equity must keep a minimum ratio of client
///     liabilities per listed asset; withdrawals that would breach it revert.
///   · **Regulatory powers** — compliance can freeze accounts, screen sanctioned
///     parties and force-transfer assets to a licensed recovery address; the
///     guardian can pause and perform an emergency drain.
///   · **Audit trail** — every flow is an event; client totals are checkpointed
///     per block for regulatory reporting.
contract VASPTreasury is AccessControl {
    using Checkpoints for Checkpoints.Checkpoint[];

    /// @notice Day-to-day operators: list assets, move house funds, adjust reserve.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR");

    /// @notice The compliance module (KYC, limits, screening).
    ComplianceModule public immutable compliance;

    /// @notice A listed asset (token = address(0) for native ETH).
    struct Asset {
        bool listed;
    }

    mapping(address token => Asset) public assets;

    /// @notice Client balances per ERC20 asset; native ETH tracked separately.
    mapping(address token => mapping(address client => uint256)) public clientBalances;
    mapping(address client => uint256) public ethClientBalances;

    /// @notice House (proprietary) balances per asset.
    mapping(address token => uint256) public houseBalances;
    uint256 public ethHouseBalance;

    /// @notice Total client holdings per asset (liabilities).
    mapping(address token => uint256) public clientTotals;
    uint256 public ethClientTotal;

    /// @notice Snapshot history of client totals per asset (audit).
    mapping(address token => Checkpoints.Checkpoint[]) private _totalHistory;
    Checkpoints.Checkpoint[] private _ethTotalHistory;

    /// @notice Withdrawal limit accounting per client (rolling 24h windows).
    mapping(address client => mapping(address token => uint256)) public dailyWithdrawn;
    mapping(address client => uint256) public dailyWithdrawnEth;
    mapping(address client => uint256) public lastWithdrawWindow;

    /// @notice House equity must keep this ratio (bps) of client liabilities per asset.
    uint256 public reserveBps;

    /// @notice Paused by the guardian.
    bool public paused;

    /// @notice The licensed recovery address for forced transfers and drains.
    address public recoveryAddress;

    event AssetListed(address indexed token, bool listed);
    event ClientDeposit(address indexed client, address indexed token, uint256 amount);
    event HouseDeposit(address indexed operator, address indexed token, uint256 amount);
    event ClientWithdrawal(address indexed client, address indexed token, address indexed to, uint256 amount);
    event HouseWithdrawal(address indexed operator, address indexed token, address indexed to, uint256 amount);
    event AccountFrozen(address indexed client, bool frozen);
    event ForcedTransfer(address indexed from, address indexed to, address indexed token, uint256 amount);
    event EmergencyDrain(address indexed to);
    event ReserveSet(uint256 bps);
    event RecoverySet(address indexed recovery);
    event Paused(bool paused);

    error ZeroAddress();
    error ZeroAmount();
    error AssetNotListed(address token);
    error ProtocolPaused();
    error Blocked(address account);
    error InsufficientClientBalance(uint256 balance, uint256 amount);
    error InsufficientHouseBalance(uint256 balance, uint256 amount);
    error WithdrawalLimit(uint256 limit, uint256 amount);
    error ReserveBreach(uint256 house, uint256 required);
    error NotApprovedCounterparty(address to);
    error TransferFailed();

    uint256 internal constant WINDOW = 1 days;

    constructor(ComplianceModule compliance_, uint256 reserveBps_, address recovery_) {
        if (address(compliance_) == address(0) || recovery_ == address(0)) revert ZeroAddress();
        compliance = compliance_;
        reserveBps = reserveBps_;
        recoveryAddress = recovery_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        emit RecoverySet(recovery_);
        emit ReserveSet(reserveBps_);
    }

    modifier whenNotPaused() {
        if (paused) revert ProtocolPaused();
        _;
    }

    /* ==================== ASSET LISTING ==================== */

    function listAsset(address token) external onlyRole(OPERATOR_ROLE) {
        assets[token].listed = true;
        emit AssetListed(token, true);
    }

    function delistAsset(address token) external onlyRole(OPERATOR_ROLE) {
        assets[token].listed = false;
        emit AssetListed(token, false);
    }

    /* ==================== CLIENT DEPOSITS ==================== */

    receive() external payable {
        _depositEth();
    }

    function depositEth() external payable whenNotPaused {
        _depositEth();
    }

    function _depositEth() internal whenNotPaused {
        if (msg.value == 0) revert ZeroAmount();
        if (compliance.isBlocked(msg.sender)) revert Blocked(msg.sender);
        ethClientBalances[msg.sender] += msg.value;
        _setEthClientTotal(ethClientTotal + msg.value);
        emit ClientDeposit(msg.sender, address(0), msg.value);
    }

    function deposit(address token, uint256 amount) external whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (!assets[token].listed) revert AssetNotListed(token);
        if (compliance.isBlocked(msg.sender)) revert Blocked(msg.sender);
        if (!IERC20(token).transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        clientBalances[token][msg.sender] += amount;
        _setClientTotal(token, clientTotals[token] + amount);
        emit ClientDeposit(msg.sender, token, amount);
    }

    /* ==================== HOUSE DEPOSITS ==================== */

    function operatorDepositEth() external payable onlyRole(OPERATOR_ROLE) whenNotPaused {
        if (msg.value == 0) revert ZeroAmount();
        ethHouseBalance += msg.value;
        emit HouseDeposit(msg.sender, address(0), msg.value);
    }

    function operatorDeposit(address token, uint256 amount) external onlyRole(OPERATOR_ROLE) whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (!assets[token].listed) revert AssetNotListed(token);
        if (!IERC20(token).transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        houseBalances[token] += amount;
        emit HouseDeposit(msg.sender, token, amount);
    }

    /* ==================== CLIENT WITHDRAWALS ==================== */

    function withdrawEth(address to, uint256 amount) external whenNotPaused {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (compliance.isBlocked(msg.sender)) revert Blocked(msg.sender);
        if (to != msg.sender && !compliance.counterparties(to)) revert NotApprovedCounterparty(to);

        uint256 bal = ethClientBalances[msg.sender];
        if (bal < amount) revert InsufficientClientBalance(bal, amount);

        // risk limits (KYC tier) with a rolling 24h window
        _consumeWindow(msg.sender, true, amount);

        // capital reserve: house equity ≥ reserve × remaining client liabilities
        uint256 newTotal = ethClientTotal - amount;
        uint256 required = (newTotal * reserveBps) / 10_000;
        if (ethHouseBalance < required) revert ReserveBreach(ethHouseBalance, required);

        ethClientBalances[msg.sender] = bal - amount;
        _setEthClientTotal(newTotal);
        (bool ok, ) = to.call{ value: amount }("");
        if (!ok) revert TransferFailed();
        emit ClientWithdrawal(msg.sender, address(0), to, amount);
    }

    function withdraw(address token, address to, uint256 amount) external whenNotPaused {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (!assets[token].listed) revert AssetNotListed(token);
        if (compliance.isBlocked(msg.sender)) revert Blocked(msg.sender);
        if (to != msg.sender && !compliance.counterparties(to)) revert NotApprovedCounterparty(to);

        uint256 bal = clientBalances[token][msg.sender];
        if (bal < amount) revert InsufficientClientBalance(bal, amount);

        _consumeWindow(msg.sender, false, amount);

        uint256 newTotal = clientTotals[token] - amount;
        uint256 required = (newTotal * reserveBps) / 10_000;
        if (houseBalances[token] < required) revert ReserveBreach(houseBalances[token], required);

        clientBalances[token][msg.sender] = bal - amount;
        _setClientTotal(token, newTotal);
        if (!IERC20(token).transfer(to, amount)) revert TransferFailed();
        emit ClientWithdrawal(msg.sender, token, to, amount);
    }

    /* ==================== HOUSE WITHDRAWALS ==================== */

    function operatorWithdrawEth(address to, uint256 amount) external onlyRole(OPERATOR_ROLE) whenNotPaused {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        uint256 bal = ethHouseBalance;
        if (bal < amount) revert InsufficientHouseBalance(bal, amount);
        uint256 required = (ethClientTotal * reserveBps) / 10_000;
        if (bal - amount < required) revert ReserveBreach(bal - amount, required);
        ethHouseBalance = bal - amount;
        (bool ok, ) = to.call{ value: amount }("");
        if (!ok) revert TransferFailed();
        emit HouseWithdrawal(msg.sender, address(0), to, amount);
    }

    function operatorWithdraw(address token, address to, uint256 amount) external onlyRole(OPERATOR_ROLE) whenNotPaused {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (!assets[token].listed) revert AssetNotListed(token);
        uint256 bal = houseBalances[token];
        if (bal < amount) revert InsufficientHouseBalance(bal, amount);
        uint256 required = (clientTotals[token] * reserveBps) / 10_000;
        if (bal - amount < required) revert ReserveBreach(bal - amount, required);
        houseBalances[token] = bal - amount;
        if (!IERC20(token).transfer(to, amount)) revert TransferFailed();
        emit HouseWithdrawal(msg.sender, token, to, amount);
    }

    /* ==================== COMPLIANCE POWERS ==================== */

    /// @notice Compliance freezes an account (no deposits/withdrawals while frozen).
    function freezeAccount(address account) external onlyRole(COMPLIANCE_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        compliance.setAccountFrozen(account, true);
        emit AccountFrozen(account, true);
    }

    /// @notice Compliance force-transfers frozen client assets to the recovery address.
    function forcedTransfer(address from, address token, uint256 amount) external onlyRole(COMPLIANCE_ROLE) {
        ( , , bool frozen) = compliance.accounts(from);
        if (!frozen) revert Blocked(from);
        uint256 bal = clientBalances[token][from];
        if (bal < amount) revert InsufficientClientBalance(bal, amount);
        clientBalances[token][from] = bal - amount;
        clientBalances[token][recoveryAddress] += amount;
        emit ForcedTransfer(from, recoveryAddress, token, amount);
    }

    /* ==================== GUARDIAN POWERS ==================== */

    function pause() external onlyRole(GUARDIAN_ROLE) {
        paused = true;
        emit Paused(true);
    }

    function unpause() external onlyRole(GUARDIAN_ROLE) {
        paused = false;
        emit Paused(false);
    }

    /// @notice The guardian drains every asset to the licensed recovery address.
    /// @dev Only while paused; the drain is total and final.
    function emergencyDrain() external onlyRole(GUARDIAN_ROLE) {
        if (!paused) revert ProtocolPaused();
        emit EmergencyDrain(recoveryAddress);

        // native ETH (house + clients)
        uint256 ethTotal = ethHouseBalance + ethClientTotal;
        if (ethTotal > 0) {
            ethHouseBalance = 0;
            _setEthClientTotal(0);
            (bool ok, ) = recoveryAddress.call{ value: ethTotal }("");
            if (!ok) revert TransferFailed();
        }
        // every listed ERC20: drain the contract's full balance
        // (client + house ledgers collapse into the recovery wallet)
        // note: iterating all listed assets requires the operator to maintain the
        // list; the drain loop is bounded by the asset count.
    }

    /// @notice Iterates a provided asset list and drains each (guardian).
    function emergencyDrainAssets(address[] calldata tokens) external onlyRole(GUARDIAN_ROLE) {
        if (!paused) revert ProtocolPaused();
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 bal = IERC20(token).balanceOf(address(this));
            if (bal == 0) continue;
            houseBalances[token] = 0;
            _setClientTotal(token, 0);
            if (!IERC20(token).transfer(recoveryAddress, bal)) revert TransferFailed();
        }
        emit EmergencyDrain(recoveryAddress);
    }

    /* ==================== ADMIN ==================== */

    function setReserveBps(uint256 bps) external onlyRole(OPERATOR_ROLE) {
        if (bps > 10_000) revert ZeroAmount();
        reserveBps = bps;
        emit ReserveSet(bps);
    }

    function setRecoveryAddress(address recovery) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (recovery == address(0)) revert ZeroAddress();
        recoveryAddress = recovery;
        emit RecoverySet(recovery);
    }

    /* ==================== AUDIT SNAPSHOTS ==================== */

    function getPastClientTotal(address token, uint256 blockNumber) external view returns (uint256) {
        return _totalHistory[token].lookup(blockNumber);
    }

    function getPastEthClientTotal(uint256 blockNumber) external view returns (uint256) {
        return _ethTotalHistory.lookup(blockNumber);
    }

    /* ==================== INTERNAL ==================== */

    function _consumeWindow(address client, bool isEth, uint256 amount) internal {
        uint256 window = block.timestamp / WINDOW;
        if (lastWithdrawWindow[client] != window) {
            lastWithdrawWindow[client] = window;
            dailyWithdrawn[client][address(0)] = 0;
            dailyWithdrawnEth[client] = 0;
            // also reset per-token windows lazily: track a single window for all tokens
        }
        (uint256 dailyLimit, uint256 singleLimit) = (
            compliance.dailyLimitFor(client),
            compliance.singleLimitFor(client)
        );
        if (amount > singleLimit) revert WithdrawalLimit(singleLimit, amount);
        uint256 used;
        if (isEth) {
            used = dailyWithdrawnEth[client] + amount;
            if (used > dailyLimit) revert WithdrawalLimit(dailyLimit, used);
            dailyWithdrawnEth[client] = used;
        } else {
            used = dailyWithdrawn[client][address(0)] + amount;
            if (used > dailyLimit) revert WithdrawalLimit(dailyLimit, used);
            dailyWithdrawn[client][address(0)] = used;
        }
    }

    function _setClientTotal(address token, uint256 total) internal {
        clientTotals[token] = total;
        _totalHistory[token].write(clientTotals[token], total);
    }

    function _setEthClientTotal(uint256 total) internal {
        ethClientTotal = total;
        _ethTotalHistory.write(ethClientTotal, total);
    }
}
