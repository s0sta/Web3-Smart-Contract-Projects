// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {AtaaRegistry} from "./AtaaRegistry.sol";
import {AtaaVault} from "./AtaaVault.sol";

/// @title AtaaAllocations
/// @notice The committee desk: a 2-of-3 panel proposes and approves
///         disbursements from the vault to beneficiaries, within per-category
///         budgets. Each approved allocation flows through the vault and is
///         attributed to specific donations (donor provenance).
contract AtaaAllocations is AccessControl {
    /// @notice Committee members vote on allocations.
    bytes32 public constant COMMITTEE_ROLE = keccak256("COMMITTEE");

    /// @notice One allocation proposal.
    struct Proposal {
        uint256 beneficiaryId;
        address beneficiaryWallet;
        uint256 amount;
        string purpose;
        mapping(address member => bool) voted;
        uint256 approvals;
        uint256 rejections;
        bool executed;
        bool rejected;
    }

    Proposal[] public proposals;

    /// @notice Per-category budgets (denominated in the payment token).
    mapping(AtaaRegistry.Category cat => uint256) public budgets;
    mapping(AtaaRegistry.Category cat => uint256) public spentInCategory;

    AtaaRegistry public immutable registry;
    AtaaVault public immutable vault;

    event AllocationProposed(uint256 indexed proposalId, uint256 beneficiaryId, uint256 amount, string purpose);
    event AllocationVoted(uint256 indexed proposalId, address indexed member, bool approve);
    event AllocationExecuted(uint256 indexed proposalId, uint256 amount);
    event BudgetSet(AtaaRegistry.Category cat, uint256 budget);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownProposal(uint256 proposalId);
    error AlreadyDecided(uint256 proposalId);
    error AlreadyVoted(uint256 proposalId, address member);
    error BudgetExceeded(AtaaRegistry.Category cat, uint256 spent, uint256 budget);
    error InactiveBeneficiary(uint256 beneficiaryId);
    error TransferFailed();

    constructor(AtaaRegistry registry_, AtaaVault vault_) {
        if (address(registry_) == address(0) || address(vault_) == address(0)) revert ZeroAddress();
        registry = registry_;
        vault = vault_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(COMMITTEE_ROLE, msg.sender);
    }

    /* ==================== PROPOSE & VOTE ==================== */

    function propose(
        uint256 beneficiaryId,
        address beneficiaryWallet,
        uint256 amount,
        string calldata purpose
    ) external onlyRole(COMMITTEE_ROLE) returns (uint256 proposalId) {
        if (amount == 0) revert ZeroAmount();
        if (!registry.isActiveBeneficiary(beneficiaryId)) revert InactiveBeneficiary(beneficiaryId);
        ( , AtaaRegistry.Category cat, , , , ) = registry.beneficiaries(beneficiaryId);
        uint256 spent = spentInCategory[cat];
        uint256 budget = budgets[cat];
        if (budget != 0 && spent + amount > budget) revert BudgetExceeded(cat, spent, budget);

        proposalId = proposals.length;
        proposals.push();
        Proposal storage p = proposals[proposalId];
        p.beneficiaryId = beneficiaryId;
        p.beneficiaryWallet = beneficiaryWallet;
        p.amount = amount;
        p.purpose = purpose;
        emit AllocationProposed(proposalId, beneficiaryId, amount, purpose);
    }

    function vote(uint256 proposalId, bool approve) external onlyRole(COMMITTEE_ROLE) {
        Proposal storage p = proposals[proposalId];
        if (p.amount == 0) revert UnknownProposal(proposalId);
        if (p.executed || p.rejected) revert AlreadyDecided(proposalId);
        if (p.voted[msg.sender]) revert AlreadyVoted(proposalId, msg.sender);

        p.voted[msg.sender] = true;
        if (approve) p.approvals += 1;
        else p.rejections += 1;
        emit AllocationVoted(proposalId, msg.sender, approve);

        if (p.approvals >= 2) {
            p.executed = true;
            _execute(proposalId);
        } else if (p.rejections >= 2) {
            p.rejected = true;
        }
    }

    function _execute(uint256 proposalId) internal {
        Proposal storage p = proposals[proposalId];
        ( , AtaaRegistry.Category cat, , , , ) = registry.beneficiaries(p.beneficiaryId);
        spentInCategory[cat] += p.amount;
        vault.disburse(p.beneficiaryId, p.beneficiaryWallet, p.amount, p.purpose);
        emit AllocationExecuted(proposalId, p.amount);
    }

    /* ==================== ADMIN ==================== */

    function setBudget(AtaaRegistry.Category cat, uint256 budget) external onlyRole(DEFAULT_ADMIN_ROLE) {
        budgets[cat] = budget;
        emit BudgetSet(cat, budget);
    }
}
