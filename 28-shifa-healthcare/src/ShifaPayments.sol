// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {ShifaRegistry} from "./ShifaRegistry.sol";
import {ShifaInsurance} from "./ShifaInsurance.sol";
import {ShifaTreasury} from "./ShifaTreasury.sol";

/// @title ShifaPayments
/// @notice Paying for care. When an insurer covers part of a treatment, the
///         patient settles only their share here; when there is no insurance the
///         patient pays the full amount. Every payment is split into the provider
///         payout and the platform fee, and the provider has a running earnings
///         balance the dApp can show.
contract ShifaPayments is AccessControl {
    /// @notice One patient payment.
    struct PaymentReceipt {
        address patient;
        address provider;
        uint256 amount;
        uint256 fee;
        bytes32 serviceHash;
        uint256 claimId; // 0 when there is no insurance claim
        bool insured;
        uint64 paidAt;
    }

    PaymentReceipt[] public receipts;

    mapping(address patient => uint256[]) private _byPatient;
    mapping(address provider => uint256[]) private _byProvider;
    mapping(address provider => uint256) public earnings;

    ShifaRegistry public immutable registry;
    ShifaInsurance public immutable insurance;
    ShifaTreasury public immutable treasury;
    IERC20 public immutable paymentToken;

    /// @notice Platform fee on direct payments (bps). Claims already carry the
    ///         insurer's own pricing, so insured copays are cheaper for the venue.
    uint256 public feeBps;
    uint256 public insuredFeeBps;

    event ServicePaid(uint256 indexed receiptId, address indexed patient, address indexed provider, uint256 amount, uint256 fee, bool insured);
    event FeesSet(uint256 feeBps, uint256 insuredFeeBps);

    error ZeroAddress();
    error ZeroAmount();
    error NotPatient();
    error UnknownClaim(uint256 claimId);
    error ClaimNotApproved(uint256 claimId);
    error ClaimAlreadySettled(uint256 claimId);
    error WrongAmount(uint256 expected, uint256 provided);
    error TransferFailed();

    constructor(ShifaRegistry registry_, ShifaInsurance insurance_, ShifaTreasury treasury_, IERC20 paymentToken_) {
        if (address(registry_) == address(0) || address(insurance_) == address(0) || address(treasury_) == address(0) || address(paymentToken_) == address(0)) {
            revert ZeroAddress();
        }
        registry = registry_;
        insurance = insurance_;
        treasury = treasury_;
        paymentToken = paymentToken_;
        feeBps = 150; // 1.5%
        insuredFeeBps = 50; // 0.5%
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /* ==================== DIRECT PAYMENT ==================== */

    /// @notice Pay for a service without insurance.
    function payForService(address provider, uint256 amount, bytes32 serviceHash) external returns (uint256 receiptId) {
        if (!registry.isVerifiedProvider(provider)) revert ZeroAmount();
        if (!registry.isActive(msg.sender)) revert NotPatient();
        if (amount == 0) revert ZeroAmount();
        receiptId = _settle(msg.sender, provider, amount, amount, feeBps, serviceHash, 0, false);
    }

    /// @notice Pay the patient's copay for an approved insurance claim.
    function payCopay(uint256 claimId, bytes32 serviceHash) external returns (uint256 receiptId) {
        // the claim links to its pre-authorisation; here we only need the split
        ( , address provider, , , uint256 patientShare, , , , , bool paid) = insurance.claims(claimId);
        if (provider == address(0)) revert UnknownClaim(claimId);
        if (!paid) revert ClaimNotApproved(claimId);
        if (patientShare == 0) revert ClaimAlreadySettled(claimId);
        if (!registry.isActive(msg.sender)) revert NotPatient();

        receiptId = _settle(msg.sender, provider, patientShare, patientShare, insuredFeeBps, serviceHash, claimId, true);
    }

    function _settle(
        address patient,
        address provider,
        uint256 amount,
        uint256 charge,
        uint256 feeBps_,
        bytes32 serviceHash,
        uint256 claimId,
        bool insured
    ) internal returns (uint256 receiptId) {
        uint256 fee = (charge * feeBps_) / 10_000;
        uint256 providerShare = charge - fee;

        if (!paymentToken.transferFrom(patient, address(this), charge)) revert TransferFailed();
        if (providerShare > 0) {
            if (!paymentToken.transfer(provider, providerShare)) revert TransferFailed();
            earnings[provider] += providerShare;
        }
        if (fee > 0) {
            if (!paymentToken.approve(address(treasury), fee)) revert TransferFailed();
            treasury.receiveFees(fee);
        }

        receiptId = receipts.length;
        receipts.push();
        PaymentReceipt storage r = receipts[receiptId];
        r.patient = patient;
        r.provider = provider;
        r.amount = amount;
        r.fee = fee;
        r.serviceHash = serviceHash;
        r.claimId = claimId;
        r.insured = insured;
        r.paidAt = uint64(block.timestamp);
        _byPatient[patient].push(receiptId);
        _byProvider[provider].push(receiptId);
        emit ServicePaid(receiptId, patient, provider, amount, fee, insured);
    }

    /* ==================== QUERIES ==================== */

    function receiptsOf(address patient) external view returns (uint256[] memory) {
        return _byPatient[patient];
    }

    function receiptsFor(address provider) external view returns (uint256[] memory) {
        return _byProvider[provider];
    }

    function receiptCount() external view returns (uint256) {
        return receipts.length;
    }

    /* ==================== ADMIN ==================== */

    function setFees(uint256 feeBps_, uint256 insuredFeeBps_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (feeBps_ > 1000 || insuredFeeBps_ > 1000) revert ZeroAmount();
        feeBps = feeBps_;
        insuredFeeBps = insuredFeeBps_;
        emit FeesSet(feeBps_, insuredFeeBps_);
    }
}
