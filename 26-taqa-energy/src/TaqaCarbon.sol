// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {TaqaRegistry} from "./TaqaRegistry.sol";

/// @title TaqaCarbon
/// @notice Carbon credits: auditors mint verified emission reductions with
///         vintages; credits transfer and retire through the retirement desk.
contract TaqaCarbon is AccessControl {
    /// @notice The auditor role mints credits.
    bytes32 public constant AUDITOR_ROLE = keccak256("AUDITOR");

    /// @notice The market escrows credits.
    bytes32 public constant MARKET_ROLE = keccak256("MARKET");

    /// @notice The retirement desk burns credits.
    bytes32 public constant RETIREMENT_ROLE = keccak256("RETIREMENT");

    /// @notice One verified emission reduction.
    struct Ver {
        address project;
        uint256 amount; // tonnes CO2e
        uint64 vintage; // year
        uint64 verifiedAt;
    }

    Ver[] public vers;

    mapping(address holder => uint256) public balanceOf;
    uint256 public totalSupply;

    TaqaRegistry public immutable registry;

    event Minted(uint256 indexed verId, address indexed project, uint256 amount, uint64 vintage);
    event Transferred(address indexed from, address indexed to, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error NotAuditor();
    error InsufficientBalance(uint256 balance, uint256 amount);

    constructor(TaqaRegistry registry_) {
        if (address(registry_) == address(0)) revert ZeroAddress();
        registry = registry_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(AUDITOR_ROLE, msg.sender);
        _grantRole(MARKET_ROLE, msg.sender);
        _grantRole(RETIREMENT_ROLE, msg.sender);
    }

    function mint(address project, uint256 amount, uint64 vintage) external onlyRole(AUDITOR_ROLE) returns (uint256 verId) {
        if (project == address(0) || amount == 0) revert ZeroAmount();
        if (vintage == 0) revert ZeroAmount();
        verId = vers.length;
        vers.push();
        Ver storage v = vers[verId];
        v.project = project;
        v.amount = amount;
        v.vintage = vintage;
        v.verifiedAt = uint64(block.timestamp);

        balanceOf[project] += amount;
        totalSupply += amount;
        emit Minted(verId, project, amount, vintage);
    }

    /// @notice The market moves escrowed credits.
    function transferFromMarket(address from, address to, uint256 amount) external onlyRole(MARKET_ROLE) {
        uint256 bal = balanceOf[from];
        if (bal < amount) revert InsufficientBalance(bal, amount);
        balanceOf[from] = bal - amount;
        balanceOf[to] += amount;
        emit Transferred(from, to, amount);
    }

    /// @notice The retirement desk burns retired certificates.
    function retireFrom(address from, uint256 amount) external onlyRole(RETIREMENT_ROLE) {
        uint256 bal = balanceOf[from];
        if (bal < amount) revert InsufficientBalance(bal, amount);
        balanceOf[from] = bal - amount;
        totalSupply -= amount;
        emit Transferred(from, address(0), amount);
    }

    function transfer(address to, uint256 amount) external {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        uint256 bal = balanceOf[msg.sender];
        if (bal < amount) revert InsufficientBalance(bal, amount);
        balanceOf[msg.sender] = bal - amount;
        balanceOf[to] += amount;
        emit Transferred(msg.sender, to, amount);
    }
}
