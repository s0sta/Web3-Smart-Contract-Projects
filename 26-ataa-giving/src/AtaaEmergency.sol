// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {AtaaRegistry} from "./AtaaRegistry.sol";
import {AtaaVault} from "./AtaaVault.sol";

/// @title AtaaEmergency
/// @notice Urgent campaigns: the committee opens a campaign (disaster relief,
///         medical emergency) with a target and deadline; anyone donates
///         directly to it; a single committee member can fast-track the
///         disbursement while the campaign is live.
contract AtaaEmergency is AccessControl {
    /// @notice The committee opens campaigns and fast-tracks payouts.
    bytes32 public constant COMMITTEE_ROLE = keccak256("COMMITTEE");

    /// @notice One campaign.
    struct Campaign {
        uint256 beneficiaryId;
        address beneficiaryWallet;
        uint256 target;
        uint256 raised;
        uint256 disbursed;
        uint64 deadline;
        string title;
        bool closed;
    }

    Campaign[] public campaigns;

    /// @notice Donations to a campaign.
    struct CampaignDonation {
        uint256 campaignId;
        address donor;
        uint256 amount;
    }

    CampaignDonation[] public campaignDonations;
    mapping(uint256 campaignId => uint256[]) public donationsOfCampaign;

    AtaaRegistry public immutable registry;
    AtaaVault public immutable vault;
    IERC20 public immutable paymentToken;

    event CampaignOpened(uint256 indexed campaignId, uint256 beneficiaryId, uint256 target, string title);
    event CampaignDonated(uint256 indexed campaignId, address indexed donor, uint256 amount);
    event CampaignDisbursed(uint256 indexed campaignId, uint256 amount);
    event CampaignClosed(uint256 indexed campaignId);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownCampaign(uint256 campaignId);
    error AlreadyClosed(uint256 campaignId);
    error CampaignExpired(uint256 campaignId, uint256 deadline);
    error NothingRaised(uint256 campaignId);
    error TransferFailed();

    constructor(AtaaRegistry registry_, AtaaVault vault_, IERC20 paymentToken_) {
        if (address(registry_) == address(0) || address(vault_) == address(0) || address(paymentToken_) == address(0)) {
            revert ZeroAddress();
        }
        registry = registry_;
        vault = vault_;
        paymentToken = paymentToken_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(COMMITTEE_ROLE, msg.sender);
    }

    /* ==================== CAMPAIGNS ==================== */

    function openCampaign(
        uint256 beneficiaryId,
        address beneficiaryWallet,
        uint256 target,
        uint64 durationDays,
        string calldata title
    ) external onlyRole(COMMITTEE_ROLE) returns (uint256 campaignId) {
        if (target == 0 || durationDays == 0) revert ZeroAmount();
        if (!registry.isActiveBeneficiary(beneficiaryId)) revert ZeroAmount();
        campaignId = campaigns.length;
        campaigns.push();
        Campaign storage c = campaigns[campaignId];
        c.beneficiaryId = beneficiaryId;
        c.beneficiaryWallet = beneficiaryWallet;
        c.target = target;
        c.deadline = uint64(block.timestamp + durationDays * 1 days);
        c.title = title;
        emit CampaignOpened(campaignId, beneficiaryId, target, title);
    }

    /// @notice Anyone may give to a live campaign.
    function donate(uint256 campaignId, uint256 amount) external {
        Campaign storage c = campaigns[campaignId];
        if (c.target == 0) revert UnknownCampaign(campaignId);
        if (c.closed) revert AlreadyClosed(campaignId);
        if (block.timestamp > c.deadline) revert CampaignExpired(campaignId, c.deadline);
        if (amount == 0) revert ZeroAmount();
        if (!paymentToken.transferFrom(msg.sender, address(vault), amount)) revert TransferFailed();
        c.raised += amount;
        vault.recordDonation(msg.sender, amount);
        campaignDonations.push(CampaignDonation({ campaignId: campaignId, donor: msg.sender, amount: amount }));
        donationsOfCampaign[campaignId].push(campaignDonations.length - 1);
        emit CampaignDonated(campaignId, msg.sender, amount);
    }

    /// @notice A single committee member fast-tracks a disbursement while the
    ///         campaign is live (urgent relief).
    function fastDisburse(uint256 campaignId, uint256 amount) external onlyRole(COMMITTEE_ROLE) {
        Campaign storage c = campaigns[campaignId];
        if (c.target == 0) revert UnknownCampaign(campaignId);
        if (c.closed) revert AlreadyClosed(campaignId);
        if (amount == 0) revert ZeroAmount();
        if (c.raised - c.disbursed < amount) revert NothingRaised(campaignId);
        c.disbursed += amount;
        vault.disburse(c.beneficiaryId, c.beneficiaryWallet, amount, c.title);
        emit CampaignDisbursed(campaignId, amount);
        if (c.raised >= c.target) c.closed = true;
    }

    /// @notice Closes the campaign; unspent raised funds remain in the vault
    ///         for the beneficiary's category.
    function closeCampaign(uint256 campaignId) external onlyRole(COMMITTEE_ROLE) {
        Campaign storage c = campaigns[campaignId];
        if (c.target == 0) revert UnknownCampaign(campaignId);
        c.closed = true;
        emit CampaignClosed(campaignId);
    }

    function raisedOf(uint256 campaignId) external view returns (uint256) {
        return campaigns[campaignId].raised;
    }
}
