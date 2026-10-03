// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {Checkpoints} from "./lib/Checkpoints.sol";
import {MawaridCompliance} from "./MawaridCompliance.sol";

/// @title MawaridShares
/// @notice The fractional share token of the platform — a from-scratch ERC-20 whose
///         transfers are compliance-gated (KYC, sanctions, exposure caps) and whose
///         balances are checkpointed per block so distributions and governance can
///         read historical entitlements. The primary market is the only minter;
///         burning happens on liquidation.
contract MawaridShares is AccessControl {
    using Checkpoints for Checkpoints.Checkpoint[];

    /// @notice The primary market (sole minter).
    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER");

    /// @notice The compliance module.
    MawaridCompliance public immutable compliance;

    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public totalSupply;

    mapping(address holder => uint256) public balanceOf;
    mapping(address holder => mapping(address spender => uint256)) public allowance;

    mapping(address holder => Checkpoints.Checkpoint[]) private _balanceHistory;

    /// @notice The asset these shares represent.
    uint256 public assetId;

    bool public transfersEnabled;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event TransfersEnabled(bool enabled);

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientBalance(uint256 balance, uint256 amount);
    error InsufficientAllowance(uint256 allowed, uint256 amount);
    error TransfersDisabled();
    error TransferBlocked(address holder);
    error NotIssuer();

    constructor(MawaridCompliance compliance_, uint256 assetId_, string memory name_, string memory symbol_) {
        if (address(compliance_) == address(0)) revert ZeroAddress();
        compliance = compliance_;
        assetId = assetId_;
        name = name_;
        symbol = symbol_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ISSUER_ROLE, msg.sender);
    }

    modifier onlyIssuer() {
        if (!hasRole(ISSUER_ROLE, msg.sender)) revert NotIssuer();
        _;
    }

    /* ==================== ERC-20 CORE ==================== */

    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) revert ZeroAddress();
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed < amount) revert InsufficientAllowance(allowed, amount);
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (!transfersEnabled) revert TransfersDisabled();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (!compliance.canHold(assetId, from)) revert TransferBlocked(from);
        if (!compliance.canHold(assetId, to)) revert TransferBlocked(to);

        uint256 fromBal = balanceOf[from];
        if (fromBal < amount) revert InsufficientBalance(fromBal, amount);

        // exposure cap on the receiving side
        compliance.validateReceipt(assetId, to, balanceOf[to], amount);

        _setBalance(from, fromBal - amount);
        _setBalance(to, balanceOf[to] + amount);
        emit Transfer(from, to, amount);
    }

    /* ==================== ISSUANCE & BURN ==================== */

    function mint(address to, uint256 amount) external onlyIssuer {
        if (amount == 0) revert ZeroAmount();
        if (!compliance.canHold(assetId, to)) revert TransferBlocked(to);
        compliance.validateReceipt(assetId, to, balanceOf[to], amount);
        totalSupply += amount;
        _setBalance(to, balanceOf[to] + amount);
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external onlyIssuer {
        uint256 fromBal = balanceOf[from];
        if (fromBal < amount) revert InsufficientBalance(fromBal, amount);
        totalSupply -= amount;
        _setBalance(from, fromBal - amount);
        emit Transfer(from, address(0), amount);
    }

    function setTransfersEnabled(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        transfersEnabled = enabled;
        emit TransfersEnabled(enabled);
    }

    /* ==================== SNAPSHOTS ==================== */

    function getPastBalance(address holder, uint256 blockNumber) external view returns (uint256) {
        return _balanceHistory[holder].lookup(blockNumber);
    }

    function _setBalance(address holder, uint256 newBalance) internal {
        balanceOf[holder] = newBalance;
        _balanceHistory[holder].write(_balanceHistory[holder].latest(), newBalance);
    }
}
