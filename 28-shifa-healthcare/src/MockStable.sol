// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";

/// @title MockStable
/// @notice A minimal, fully-documented stablecoin stand-in ("AED-S") used to denominate
///         service charges and treasury payments in the demo deployment.
/// @dev Only the configured vault/registry may mint and burn — mirrors the discipline a
///      real AED-pegged stable would enforce through its issuer. Not audited, testnet only.
contract MockStable is IERC20 {
    /// @notice ERC-20 metadata.
    string public name = "AED Stable";
    string public symbol = "AED-S";
    uint8 public constant decimals = 18;

    /// @notice Total supply.
    uint256 public totalSupply;

    /// @notice Balances.
    mapping(address => uint256) public balanceOf;

    /// @notice Allowances.
    mapping(address => mapping(address => uint256)) public allowance;

    /// @notice The sole address allowed to mint and burn.
    address public minter;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error ZeroAddress();
    error NotMinter(address caller);
    error InsufficientBalance(uint256 balance, uint256 amount);
    error InsufficientAllowance(uint256 allowed, uint256 amount);

    modifier onlyMinter() {
        if (msg.sender != minter) revert NotMinter(msg.sender);
        _;
    }

    constructor() {
        minter = msg.sender;
    }

    /// @notice Re-points the minter (deploy-time wiring only).
    function setMinter(address newMinter) external onlyMinter {
        if (newMinter == address(0)) revert ZeroAddress();
        minter = newMinter;
    }

    /// @notice Mints `amount` to `to` — restricted to the configured minter.
    function mint(address to, uint256 amount) external onlyMinter {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    /// @notice Burns `amount` from `from` — restricted to the configured minter.
    function burn(address from, uint256 amount) external onlyMinter {
        uint256 bal = balanceOf[from];
        if (bal < amount) revert InsufficientBalance(bal, amount);
        balanceOf[from] = bal - amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed < amount) revert InsufficientAllowance(allowed, amount);
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = balanceOf[from];
        if (bal < amount) revert InsufficientBalance(bal, amount);
        balanceOf[from] = bal - amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}
