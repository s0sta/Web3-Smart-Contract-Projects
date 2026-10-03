// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";
import {AccessControl} from "./AccessControl.sol";
import {Checkpoints} from "./lib/Checkpoints.sol";

/// @title WaqfVault
/// @notice A Sharia-compliant endowment (waqf): the corpus is irrevocable — once endowed,
///         it can never be spent, withdrawn or used as collateral. Only income (returns on
///         the corpus, recorded by the nazir/trustee board) is distributed to beneficiaries,
///         pro-rata to their registry weights. An operational fund covers administration.
///
/// @dev The corpus-preservation invariant is structural: no function in this contract can
///      reduce `totalCorpus`; the only outward transfers are (a) distribution of recorded
///      income, (b) governor-approved operational spending from the operational fund, and
///      (c) the guardian's emergency freeze which stops distributions (never the corpus).
contract WaqfVault is AccessControl {
    using Checkpoints for Checkpoints.Checkpoint[];

    /// @notice The nazir (trustee) board: records income, manages administration.
    bytes32 public constant NAZIR_ROLE = keccak256("NAZIR");

    /// @notice The endowment token (AED-pegged stable in the demo).
    IERC20 public immutable endowedToken;

    /// @notice Total endowed corpus — this number only ever grows.
    uint256 public totalCorpus;

    /// @notice Per-donor contributions (for donor-weighted governance).
    mapping(address donor => uint256) public contributions;

    /// @notice Snapshot history of donor contributions.
    mapping(address donor => Checkpoints.Checkpoint[]) private _contributionHistory;

    /// @notice Income recorded by the board but not yet distributed.
    uint256 public distributablePool;

    /// @notice Total income distributed since inception.
    uint256 public totalDistributed;

    /// @notice Administrative fund (governor-approved spending only).
    uint256 public operationalFund;

    /// @notice True while distributions are frozen by the guardian.
    bool public frozen;

    event Endowed(address indexed donor, uint256 amount);
    event IncomeRecorded(address indexed nazir, uint256 amount);
    event Distributed(uint256 amount, uint256 beneficiaryCount);
    event OperationalFunded(uint256 amount);
    event OperationalSpent(address indexed to, uint256 amount);
    event Frozen(bool frozen);

    error ZeroAddress();
    error ZeroAmount();
    error DistributionsFrozen();
    error NoIncome();
    error NoBeneficiaries();
    error InsufficientOperational(uint256 available, uint256 requested);
    error TransferFailed();

    constructor(IERC20 endowedToken_) {
        if (address(endowedToken_) == address(0)) revert ZeroAddress();
        endowedToken = endowedToken_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(NAZIR_ROLE, msg.sender);
        _grantRole(GUARDIAN_ROLE, msg.sender);
    }

    /* ==================== ENDOWMENT ==================== */

    /// @notice A donor endows assets into the corpus — irrevocable.
    /// @dev There is deliberately no withdrawal path for the corpus.
    function endow(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (!endowedToken.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        totalCorpus += amount;
        _setContribution(msg.sender, contributions[msg.sender] + amount);
        emit Endowed(msg.sender, amount);
    }

    /* ==================== INCOME & DISTRIBUTION ==================== */

    /// @notice The nazir board records income earned by the corpus (rents, Sukuk returns).
    /// @dev Income is deposited INTO this contract and tracked separately from the corpus.
    function recordIncome(uint256 amount) external onlyRole(NAZIR_ROLE) {
        if (amount == 0) revert ZeroAmount();
        if (!endowedToken.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        distributablePool += amount;
        emit IncomeRecorded(msg.sender, amount);
    }

    /// @notice A share of recorded income is set aside for administration (e.g., 10%).
    function fundOperational(uint256 amount) external onlyRole(NAZIR_ROLE) {
        if (amount == 0 || amount > distributablePool) revert ZeroAmount();
        distributablePool -= amount;
        operationalFund += amount;
        emit OperationalFunded(amount);
    }

    /// @notice Distributes the entire income pool to beneficiaries pro-rata.
    /// @param beneficiaries  the beneficiary addresses (from the registry)
    /// @param weights        their weight in bps each; must sum to 10,000
    function distribute(
        address[] calldata beneficiaries,
        uint256[] calldata weights
    ) external returns (uint256 total) {
        if (frozen) revert DistributionsFrozen();
        uint256 pool = distributablePool;
        if (pool == 0) revert NoIncome();
        if (beneficiaries.length == 0) revert NoBeneficiaries();

        distributablePool = 0;
        for (uint256 i = 0; i < beneficiaries.length; i++) {
            if (beneficiaries[i] == address(0)) revert ZeroAddress();
            uint256 share = (pool * weights[i]) / 10_000;
            if (share == 0) continue;
            if (!endowedToken.transfer(beneficiaries[i], share)) revert TransferFailed();
            total += share;
        }
        totalDistributed += total;
        emit Distributed(total, beneficiaries.length);
    }

    /* ==================== OPERATIONAL & GUARDIAN ==================== */

    /// @notice The governor executes an approved operational payment.
    /// @dev Only callable by the WaqfGovernor (set by the admin).
    function spendOperational(address to, uint256 amount) external onlyRole(NAZIR_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        if (operationalFund < amount) revert InsufficientOperational(operationalFund, amount);
        operationalFund -= amount;
        if (!endowedToken.transfer(to, amount)) revert TransferFailed();
        emit OperationalSpent(to, amount);
    }

    /// @notice The guardian freezes/unfreezes distributions (corpus untouched).
    function setFrozen(bool frozen_) external onlyRole(GUARDIAN_ROLE) {
        frozen = frozen_;
        emit Frozen(frozen_);
    }

    /* ==================== SNAPSHOTS ==================== */

    /// @notice A donor's contribution at or before `blockNumber` (governance primitive).
    function getPastContribution(address donor, uint256 blockNumber) external view returns (uint256) {
        return _contributionHistory[donor].lookup(blockNumber);
    }

    function _setContribution(address donor, uint256 newAmount) internal {
        contributions[donor] = newAmount;
        _contributionHistory[donor].write(contributions[donor], newAmount);
    }
}
