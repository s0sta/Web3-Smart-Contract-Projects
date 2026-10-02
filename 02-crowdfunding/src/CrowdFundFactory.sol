// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "./Ownable.sol";
import {CrowdFundCampaign} from "./CrowdFundCampaign.sol";

/// @title CrowdFundFactory
/// @notice The platform entry point: anyone deploys a campaign through here, and the factory
///         takes a configurable platform fee (basis points) out of every successful campaign.
/// @dev Fees accumulate in `accruedFees` and are withdrawn by the owner ("pull" pattern).
contract CrowdFundFactory is Ownable {
    /// @notice Platform fee in basis points. 100 = 1%, capped at 10%.
    uint256 public feeBps;

    /// @notice Hard cap on the fee to protect campaign creators.
    uint256 public constant MAX_FEE_BPS = 1000;

    /// @notice Every campaign ever created, in order.
    address[] public allCampaigns;

    /// @notice Whitelist of addresses this factory deployed (so only real campaigns can credit fees).
    mapping(address => bool) public isCampaign;

    /// @notice Platform fees accrued but not yet withdrawn by the owner.
    uint256 public accruedFees;

    event CampaignCreated(
        uint256 indexed id,
        address indexed campaign,
        address indexed creator,
        uint256 goal,
        uint256 deadline
    );
    event FeeBpsUpdated(uint256 oldBps, uint256 newBps);
    event FeeCredited(address indexed campaign, uint256 amount);
    event FeesWithdrawn(address indexed to, uint256 amount);

    error FeeTooHigh(uint256 bps, uint256 max);
    error NotRegisteredCampaign(address caller);
    error FeeMismatch(uint256 expected, uint256 sent);
    error EthTransferFailed();

    /// @param feeBps_ Initial platform fee in basis points.
    /// @param initialOwner Address that may update the fee and withdraw accrued fees.
    constructor(uint256 feeBps_, address initialOwner) Ownable(initialOwner) {
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh(feeBps_, MAX_FEE_BPS);
        feeBps = feeBps_;
    }

    /// @notice Number of campaigns created.
    function campaignCount() external view returns (uint256) {
        return allCampaigns.length;
    }

    /// @notice Changes the platform fee. Only affects *future* campaigns (each campaign
    ///         freezes its fee at creation).
    function setFeeBps(uint256 newBps) external onlyOwner {
        if (newBps > MAX_FEE_BPS) revert FeeTooHigh(newBps, MAX_FEE_BPS);
        emit FeeBpsUpdated(feeBps, newBps);
        feeBps = newBps;
    }

    /// @notice Deploys a new campaign owned by the caller.
    /// @param goal Minimum wei required for success.
    /// @param duration Seconds the campaign stays open.
    function createCampaign(uint256 goal, uint256 duration) external returns (CrowdFundCampaign campaign) {
        campaign = new CrowdFundCampaign(msg.sender, goal, duration, this);
        allCampaigns.push(address(campaign));
        isCampaign[address(campaign)] = true;
        emit CampaignCreated(allCampaigns.length - 1, address(campaign), msg.sender, goal, campaign.deadline());
    }

    /// @notice Called by a registered campaign to hand over its success fee. The fee ETH
    ///         is sent along with the call so it actually lives in the factory.
    function creditFees(uint256 amount) external payable {
        if (!isCampaign[msg.sender]) revert NotRegisteredCampaign(msg.sender);
        if (msg.value != amount) revert FeeMismatch(amount, msg.value);
        accruedFees += msg.value;
        emit FeeCredited(msg.sender, msg.value);
    }

    /// @notice Owner withdraws all accrued platform fees.
    function withdrawFees(address payable to) external onlyOwner {
        uint256 amount = accruedFees;
        accruedFees = 0;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
        emit FeesWithdrawn(to, amount);
    }
}
