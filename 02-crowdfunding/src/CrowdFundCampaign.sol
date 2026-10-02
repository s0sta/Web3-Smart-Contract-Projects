// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "./ReentrancyGuard.sol";
import {CrowdFundFactory} from "./CrowdFundFactory.sol";

/// @title CrowdFundCampaign
/// @notice A Kickstarter-style campaign: backers pledge ETH; if the goal is met by the
///         deadline the creator can claim everything (minus a platform fee), otherwise
///         every backer can pull their own refund.
/// @dev Security pattern: refunds use the "pull" model — each backer withdraws their own
///      funds instead of the contract pushing to everyone (a classic DoS trap).
contract CrowdFundCampaign is ReentrancyGuard {
    /// @notice Lifecycle: pledging open → after deadline, Successful if goal met else Failed.
    enum Status {
        Active,
        Successful,
        Failed
    }

    /// @notice The address that created the campaign and receives funds on success.
    address public immutable creator;

    /// @notice Minimum ETH that must be pledged for the creator to claim.
    uint256 public immutable goal;

    /// @notice Timestamp after which pledging closes and claim/refund become available.
    uint256 public immutable deadline;

    /// @notice The factory that deployed this campaign (receives the platform fee).
    CrowdFundFactory public immutable factory;

    /// @notice Platform fee in basis points (e.g. 100 = 1%), frozen at creation.
    uint256 public immutable feeBps;

    /// @notice Total ETH pledged so far.
    uint256 public totalPledged;

    /// @notice Amount each address has pledged (also their refund entitlement).
    mapping(address => uint256) public pledged;

    /// @notice True once the creator has claimed (prevents double claims).
    bool public claimed;

    event Pledged(address indexed backer, uint256 amount);
    event Claimed(address indexed creator, uint256 amount);
    event Refunded(address indexed backer, uint256 amount);

    error NotCreator();
    error CreatorCannotPledge();
    error ZeroPledge();
    error InvalidParams();
    error DeadlineNotPassed();
    error CampaignEnded();
    error NotSuccessful();
    error NotFailed();
    error AlreadyClaimed();
    error NothingToRefund();
    error EthTransferFailed();

    modifier onlyCreator() {
        if (msg.sender != creator) revert NotCreator();
        _;
    }

    /// @param creator_ Address that may claim the funds.
    /// @param goal_ Minimum wei required for success. Must be > 0.
    /// @param duration_ Seconds the campaign stays open. Must be > 0.
    /// @param factory_ The CrowdFundFactory creating this campaign.
    constructor(address creator_, uint256 goal_, uint256 duration_, CrowdFundFactory factory_) {
        if (creator_ == address(0) || goal_ == 0 || duration_ == 0) revert InvalidParams();
        creator = creator_;
        goal = goal_;
        deadline = block.timestamp + duration_;
        factory = factory_;
        feeBps = factory_.feeBps();
    }

    /// @notice Current lifecycle status, derived from time and pledges.
    function status() public view returns (Status) {
        if (block.timestamp <= deadline) return Status.Active;
        return totalPledged >= goal ? Status.Successful : Status.Failed;
    }

    /// @notice Pledge ETH to the campaign. Open until the deadline (inclusive); campaigns
    ///         may over-fund, like Kickstarter.
    function pledge() external payable {
        if (block.timestamp > deadline) revert CampaignEnded();
        if (msg.sender == creator) revert CreatorCannotPledge();
        if (msg.value == 0) revert ZeroPledge();
        pledged[msg.sender] += msg.value;
        totalPledged += msg.value;
        emit Pledged(msg.sender, msg.value);
    }

    /// @notice Creator withdraws all pledges after a successful campaign, paying the
    ///         platform fee to the factory.
    function claim() external nonReentrant onlyCreator {
        if (block.timestamp <= deadline) revert DeadlineNotPassed();
        if (totalPledged < goal) revert NotSuccessful();
        if (claimed) revert AlreadyClaimed();
        claimed = true;

        uint256 total = address(this).balance;
        uint256 fee = (total * feeBps) / 10_000;
        uint256 payout = total - fee;

        // State fully updated before any external call (checks-effects-interactions).
        if (fee > 0) factory.creditFees{value: fee}(fee);
        (bool ok,) = creator.call{value: payout}("");
        if (!ok) revert EthTransferFailed();
        emit Claimed(creator, payout);
    }

    /// @notice Backer pulls their own refund after a failed campaign. Zeroes the backer's
    ///         entitlement *before* sending ETH, so a re-entering caller cannot double-dip.
    function refund() external nonReentrant {
        if (block.timestamp <= deadline) revert DeadlineNotPassed();
        if (totalPledged >= goal) revert NotFailed();
        uint256 amount = pledged[msg.sender];
        if (amount == 0) revert NothingToRefund();

        pledged[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
        emit Refunded(msg.sender, amount);
    }
}
