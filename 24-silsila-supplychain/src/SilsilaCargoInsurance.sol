// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {SilsilaRegistry} from "./SilsilaRegistry.sol";
import {SilsilaOrders} from "./SilsilaOrders.sol";
import {SilsilaShipments} from "./SilsilaShipments.sol";

/// @title SilsilaCargoInsurance
/// @notice Cargo protection: a buyer insures a shipment against loss or damage;
///         adjusters vote on claims (2-of-3) and the payout goes to the buyer.
contract SilsilaCargoInsurance is AccessControl {
    /// @notice Adjusters evaluate claims.
    bytes32 public constant ADJUSTER_ROLE = keccak256("ADJUSTER");

    /// @notice One policy.
    struct Policy {
        uint256 shipmentId;
        address insured;
        uint256 coverValue;
        uint256 premium;
        bool active;
    }

    Policy[] public policies;
    mapping(uint256 shipmentId => uint256) public policyOfShipment;

    /// @notice One claim.
    struct Claim {
        uint256 policyId;
        uint256 amount;
        string reason;
        mapping(address adjuster => bool) voted;
        uint256 approvals;
        uint256 rejections;
        bool decided;
        bool approved;
    }

    Claim[] public claims;

    uint256 public premiumBps; // of the order value
    uint256 public totalPremiums;
    uint256 public totalPayouts;

    SilsilaRegistry public immutable registry;
    SilsilaOrders public immutable orders;
    SilsilaShipments public immutable shipments;
    IERC20 public immutable paymentToken;

    event PolicyIssued(uint256 indexed policyId, uint256 shipmentId, address indexed insured, uint256 coverValue, uint256 premium);
    event ClaimFiled(uint256 indexed claimId, uint256 policyId, uint256 amount, string reason);
    event ClaimVoted(uint256 indexed claimId, address indexed adjuster, bool approve);
    event ClaimPaid(uint256 indexed claimId, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownPolicy(uint256 policyId);
    error UnknownClaim(uint256 claimId);
    error AlreadyDecided(uint256 claimId);
    error AlreadyVoted(uint256 claimId, address adjuster);
    error NotAdjuster();
    error InsufficientPool(uint256 available, uint256 needed);
    error TransferFailed();

    constructor(
        SilsilaRegistry registry_,
        SilsilaOrders orders_,
        SilsilaShipments shipments_,
        IERC20 paymentToken_
    ) {
        if (address(registry_) == address(0) || address(orders_) == address(0) || address(shipments_) == address(0) || address(paymentToken_) == address(0)) {
            revert ZeroAddress();
        }
        registry = registry_;
        orders = orders_;
        shipments = shipments_;
        paymentToken = paymentToken_;
        premiumBps = 200; // 2% of the order value
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADJUSTER_ROLE, msg.sender);
    }

    /* ==================== POLICIES ==================== */

    function insure(uint256 shipmentId, uint256 coverValue) external returns (uint256 policyId) {
        if (coverValue == 0) revert ZeroAmount();
        if (policyOfShipment[shipmentId] != 0) revert ZeroAmount();
        (uint256 orderId, , , , , , , ) = shipments.shipments(shipmentId);
        (address buyer, , uint256 quantity, , uint256 unitPrice, , , , , , ) = orders.orders(orderId);
        if (msg.sender != buyer) revert NotAdjuster();

        uint256 premium = (coverValue * premiumBps) / 10_000;
        policyId = policies.length;
        policies.push();
        Policy storage p = policies[policyId];
        p.shipmentId = shipmentId;
        p.insured = msg.sender;
        p.coverValue = coverValue;
        p.premium = premium;
        p.active = true;
        policyOfShipment[shipmentId] = policyId + 1;

        totalPremiums += premium;
        if (!paymentToken.transferFrom(msg.sender, address(this), premium)) revert TransferFailed();
        emit PolicyIssued(policyId, shipmentId, msg.sender, coverValue, premium);
    }

    /* ==================== CLAIMS ==================== */

    function fileClaim(uint256 policyId, uint256 amount, string calldata reason) external returns (uint256 claimId) {
        Policy storage p = policies[policyId];
        if (p.insured == address(0)) revert UnknownPolicy(policyId);
        if (msg.sender != p.insured) revert NotAdjuster();
        if (amount == 0 || amount > p.coverValue) revert ZeroAmount();
        if (!p.active) revert ZeroAmount();

        claimId = claims.length;
        claims.push();
        Claim storage c = claims[claimId];
        c.policyId = policyId;
        c.amount = amount;
        c.reason = reason;
        emit ClaimFiled(claimId, policyId, amount, reason);
    }

    function voteClaim(uint256 claimId, bool approve) external onlyRole(ADJUSTER_ROLE) {
        Claim storage c = claims[claimId];
        if (c.policyId == 0 && c.amount == 0) revert UnknownClaim(claimId);
        if (c.decided) revert AlreadyDecided(claimId);
        if (c.voted[msg.sender]) revert AlreadyVoted(claimId, msg.sender);

        c.voted[msg.sender] = true;
        if (approve) c.approvals += 1;
        else c.rejections += 1;
        emit ClaimVoted(claimId, msg.sender, approve);

        if (c.approvals >= 2) {
            c.decided = true;
            c.approved = true;
            _settle(claimId);
        } else if (c.rejections >= 2) {
            c.decided = true;
        }
    }

    function _settle(uint256 claimId) internal {
        Claim storage c = claims[claimId];
        Policy storage p = policies[c.policyId];
        p.active = false;
        uint256 balance = paymentToken.balanceOf(address(this));
        if (balance < c.amount) revert InsufficientPool(balance, c.amount);
        totalPayouts += c.amount;
        if (!paymentToken.transfer(p.insured, c.amount)) revert TransferFailed();
        emit ClaimPaid(claimId, c.amount);
    }

    /* ==================== ADMIN ==================== */

    function setPremiumBps(uint256 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > 2000) revert ZeroAmount();
        premiumBps = bps;
    }
}
