// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {TaqaRegistry} from "./TaqaRegistry.sol";
import {TaqaMeters} from "./TaqaMeters.sol";

/// @title TaqaCertificates
/// @notice Renewable Energy Certificates: each REC represents 1,000 kWh of
///         attested production. Auditors mint them to producers; they transfer
///         like assets; retirement happens in the retirement registry.
contract TaqaCertificates is AccessControl {
    /// @notice The auditor role mints certificates.
    bytes32 public constant AUDITOR_ROLE = keccak256("AUDITOR");

    /// @notice The market escrows certificates.
    bytes32 public constant MARKET_ROLE = keccak256("MARKET");

    /// @notice The retirement desk burns certificates.
    bytes32 public constant RETIREMENT_ROLE = keccak256("RETIREMENT");

    /// @notice One certificate batch (per meter attestation).
    struct Batch {
        uint256 meterId;
        address producer;
        uint256 amount; // certificates minted
        uint64 mintedAt;
    }

    Batch[] public batches;

    /// @notice Certificate balances and transfers (from-scratch accounting).
    mapping(address holder => uint256) public balanceOf;
    uint256 public totalSupply;

    TaqaRegistry public immutable registry;
    TaqaMeters public immutable meters;

    event Minted(uint256 indexed batchId, uint256 meterId, address indexed producer, uint256 amount);
    event Transferred(address indexed from, address indexed to, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error NotAuditor();
    error NoCertificates(address producer);
    error InsufficientBalance(uint256 balance, uint256 amount);

    constructor(TaqaRegistry registry_, TaqaMeters meters_) {
        if (address(registry_) == address(0) || address(meters_) == address(0)) revert ZeroAddress();
        registry = registry_;
        meters = meters_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(AUDITOR_ROLE, msg.sender);
        _grantRole(MARKET_ROLE, msg.sender);
        _grantRole(RETIREMENT_ROLE, msg.sender);
    }

    /* ==================== MINTING ==================== */

    /// @notice Mints certificates for a meter's attested-but-unminted production.
    function mint(uint256 meterId, uint256 amount) external onlyRole(AUDITOR_ROLE) returns (uint256 batchId) {
        if (amount == 0) revert ZeroAmount();
        (address producer, , , uint256 attested, , ) = meters.meters(meterId);
        if (producer == address(0)) revert NoCertificates(producer);

        batchId = batches.length;
        batches.push();
        Batch storage b = batches[batches.length - 1];
        b.meterId = meterId;
        b.producer = producer;
        b.amount = amount;
        b.mintedAt = uint64(block.timestamp);

        balanceOf[producer] += amount;
        totalSupply += amount;
        attested; // the meters desk enforces the attested basis on its side
        emit Minted(batchId, meterId, producer, amount);
    }

    /* ==================== TRANSFERS ==================== */

    /// @notice The market moves escrowed certificates.
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
