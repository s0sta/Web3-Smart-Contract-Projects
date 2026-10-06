// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {AtaaRegistry} from "./AtaaRegistry.sol";
import {AtaaVault} from "./AtaaVault.sol";

/// @title AtaaSponsorships
/// @notice Monthly adoption: a donor pledges a monthly amount to a specific
///         beneficiary (orphan sponsorship, family support). Pledges renew
///         monthly, can be paused, and every renewal is a tracked vault
///         contribution — the donor follows "their" beneficiary over time.
contract AtaaSponsorships is AccessControl {
    /// @notice One pledge.
    struct Pledge {
        address donor;
        uint256 beneficiaryId;
        uint256 monthlyAmount;
        uint64 nextDue;
        uint8 renewals;
        bool active;
    }

    Pledge[] public pledges;
    mapping(address donor => uint256[]) public pledgesOf;
    mapping(address donor => mapping(uint256 beneficiaryId => uint256)) public pledgeOfPair;

    uint256 public totalMonthlyCommitted;

    AtaaRegistry public immutable registry;
    AtaaVault public immutable vault;
    IERC20 public immutable paymentToken;

    event PledgeCreated(uint256 indexed pledgeId, address indexed donor, uint256 beneficiaryId, uint256 monthlyAmount);
    event PledgeRenewed(uint256 indexed pledgeId, uint256 amount, uint8 renewal);
    event PledgePaused(uint256 indexed pledgeId);
    event PledgeResumed(uint256 indexed pledgeId);
    event PledgeCanceled(uint256 indexed pledgeId);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownPledge(uint256 pledgeId);
    error NotDonor(uint256 pledgeId);
    error NotDue(uint256 pledgeId, uint256 nextDue);
    error InactivePledge(uint256 pledgeId);
    error InactiveBeneficiary(uint256 beneficiaryId);
    error AlreadyPledged(address donor, uint256 beneficiaryId);
    error TransferFailed();

    constructor(AtaaRegistry registry_, AtaaVault vault_, IERC20 paymentToken_) {
        if (address(registry_) == address(0) || address(vault_) == address(0) || address(paymentToken_) == address(0)) {
            revert ZeroAddress();
        }
        registry = registry_;
        vault = vault_;
        paymentToken = paymentToken_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /* ==================== PLEDGES ==================== */

    function pledge(uint256 beneficiaryId, uint256 monthlyAmount) external returns (uint256 pledgeId) {
        if (monthlyAmount == 0) revert ZeroAmount();
        if (!registry.isActiveBeneficiary(beneficiaryId)) revert InactiveBeneficiary(beneficiaryId);
        if (pledgeOfPair[msg.sender][beneficiaryId] != 0) revert AlreadyPledged(msg.sender, beneficiaryId);

        pledgeId = pledges.length;
        pledges.push();
        Pledge storage p = pledges[pledgeId];
        p.donor = msg.sender;
        p.beneficiaryId = beneficiaryId;
        p.monthlyAmount = monthlyAmount;
        p.nextDue = uint64(block.timestamp + 30 days);
        p.active = true;
        pledgesOf[msg.sender].push(pledgeId);
        pledgeOfPair[msg.sender][beneficiaryId] = pledgeId + 1;
        totalMonthlyCommitted += monthlyAmount;
        emit PledgeCreated(pledgeId, msg.sender, beneficiaryId, monthlyAmount);
    }

    /// @notice Pays the monthly renewal; late renewals stay on the original
    ///         schedule (one payment per due period).
    function renew(uint256 pledgeId) external {
        Pledge storage p = pledges[pledgeId];
        if (p.donor == address(0)) revert UnknownPledge(pledgeId);
        if (msg.sender != p.donor) revert NotDonor(pledgeId);
        if (!p.active) revert InactivePledge(pledgeId);
        if (block.timestamp < p.nextDue) revert NotDue(pledgeId, p.nextDue);
        if (!registry.isActiveBeneficiary(p.beneficiaryId)) revert InactiveBeneficiary(p.beneficiaryId);

        p.renewals += 1;
        p.nextDue = uint64(block.timestamp + 30 days);
        if (!paymentToken.transferFrom(msg.sender, address(vault), p.monthlyAmount)) revert TransferFailed();
        vault.recordDonation(msg.sender, p.monthlyAmount);
        emit PledgeRenewed(pledgeId, p.monthlyAmount, p.renewals);
    }

    function pause(uint256 pledgeId) external {
        Pledge storage p = pledges[pledgeId];
        if (msg.sender != p.donor) revert NotDonor(pledgeId);
        if (!p.active) revert InactivePledge(pledgeId);
        p.active = false;
        totalMonthlyCommitted -= p.monthlyAmount;
        emit PledgePaused(pledgeId);
    }

    function resume(uint256 pledgeId) external {
        Pledge storage p = pledges[pledgeId];
        if (msg.sender != p.donor) revert NotDonor(pledgeId);
        if (p.active) revert InactivePledge(pledgeId);
        p.active = true;
        p.nextDue = uint64(block.timestamp + 30 days);
        totalMonthlyCommitted += p.monthlyAmount;
        emit PledgeResumed(pledgeId);
    }

    function cancel(uint256 pledgeId) external {
        Pledge storage p = pledges[pledgeId];
        if (msg.sender != p.donor) revert NotDonor(pledgeId);
        if (!p.active) revert InactivePledge(pledgeId);
        p.active = false;
        totalMonthlyCommitted -= p.monthlyAmount;
        pledgeOfPair[p.donor][p.beneficiaryId] = 0;
        emit PledgeCanceled(pledgeId);
    }

    function pledgesOfList(address donor) external view returns (uint256[] memory) {
        return pledgesOf[donor];
    }
}
