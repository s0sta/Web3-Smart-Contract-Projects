// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {ShifaRegistry} from "./ShifaRegistry.sol";
import {ShifaTreasury} from "./ShifaTreasury.sol";

/// @title ShifaAppointments
/// @notice Booking a visit. The patient pays a deposit that protects the clinic
///         from no-shows; completing the visit releases the deposit to the
///         provider (minus the platform fee) and unlocks rating. Cancelling in
///         time returns the deposit, and a no-show moves it to the provider.
contract ShifaAppointments is AccessControl {
    /// @notice State of a booking.
    enum Status { Booked, Completed, Canceled, NoShow }

    /// @notice One appointment.
    struct Appointment {
        address patient;
        address provider; // doctor or clinic
        uint64 slot; // when the visit is supposed to happen
        uint256 deposit;
        Status status;
        uint64 bookedAt;
    }

    Appointment[] public appointments;
    mapping(address patient => uint256[]) private _byPatient;
    mapping(address provider => uint256[]) private _byProvider;
    mapping(address patient => mapping(address provider => uint256)) public completedVisits;

    /// @notice Deposit paid back to the patient if they cancel at least this
    ///         long before the slot.
    uint256 public cancellationWindow;

    /// @notice Platform fee taken when a deposit is released (bps).
    uint256 public feeBps;

    ShifaRegistry public immutable registry;
    ShifaTreasury public immutable treasury;
    IERC20 public immutable paymentToken;

    event AppointmentBooked(uint256 indexed appointmentId, address indexed patient, address indexed provider, uint64 slot, uint256 deposit);
    event AppointmentCompleted(uint256 indexed appointmentId, uint256 providerPaid);
    event AppointmentCanceled(uint256 indexed appointmentId, uint256 refunded);
    event LateCancellation(uint256 indexed appointmentId, uint256 providerPaid);
    event AppointmentNoShow(uint256 indexed appointmentId, uint256 providerPaid);
    event WindowSet(uint256 seconds_);
    event FeeSet(uint256 bps);

    error ZeroAddress();
    error ZeroAmount();
    error NotClinicianProvider();
    error UnknownAppointment(uint256 appointmentId);
    error NotPatient(uint256 appointmentId);
    error NotProvider(uint256 appointmentId);
    error InvalidStatus(uint256 appointmentId, Status expected, Status actual);
    error SlotInPast(uint64 slot);
    error SlotTaken(uint256 appointmentId);
    error TransferFailed();

    constructor(ShifaRegistry registry_, ShifaTreasury treasury_, IERC20 paymentToken_, uint256 cancellationWindow_) {
        if (address(registry_) == address(0) || address(treasury_) == address(0) || address(paymentToken_) == address(0)) {
            revert ZeroAddress();
        }
        registry = registry_;
        treasury = treasury_;
        paymentToken = paymentToken_;
        cancellationWindow = cancellationWindow_;
        feeBps = 200; // 2%
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /* ==================== BOOKING ==================== */

    function book(address provider, uint64 slot, uint256 deposit) external returns (uint256 appointmentId) {
        if (!registry.isClinician(provider)) revert NotClinicianProvider();
        if (!registry.isActive(msg.sender)) revert NotPatient(0);
        if (slot <= block.timestamp) revert SlotInPast(slot);
        if (deposit == 0) revert ZeroAmount();

        appointmentId = appointments.length;
        appointments.push();
        Appointment storage a = appointments[appointmentId];
        a.patient = msg.sender;
        a.provider = provider;
        a.slot = slot;
        a.deposit = deposit;
        a.status = Status.Booked;
        a.bookedAt = uint64(block.timestamp);
        _byPatient[msg.sender].push(appointmentId);
        _byProvider[provider].push(appointmentId);

        if (!paymentToken.transferFrom(msg.sender, address(this), deposit)) revert TransferFailed();
        emit AppointmentBooked(appointmentId, msg.sender, provider, slot, deposit);
    }

    /* ==================== OUTCOMES ==================== */

    function complete(uint256 appointmentId) external {
        Appointment storage a = appointments[appointmentId];
        if (a.patient == address(0)) revert UnknownAppointment(appointmentId);
        if (msg.sender != a.provider) revert NotProvider(appointmentId);
        if (a.status != Status.Booked) revert InvalidStatus(appointmentId, Status.Booked, a.status);

        a.status = Status.Completed;
        completedVisits[a.patient][a.provider] += 1;
        uint256 providerPaid = _release(appointmentId);
        emit AppointmentCompleted(appointmentId, providerPaid);
    }

    function cancel(uint256 appointmentId) external {
        Appointment storage a = appointments[appointmentId];
        if (a.patient == address(0)) revert UnknownAppointment(appointmentId);
        if (msg.sender != a.patient) revert NotPatient(appointmentId);
        if (a.status != Status.Booked) revert InvalidStatus(appointmentId, Status.Booked, a.status);

        a.status = Status.Canceled;
        uint256 refunded;
        if (block.timestamp + cancellationWindow <= a.slot) {
            refunded = a.deposit;
            if (!paymentToken.transfer(a.patient, refunded)) revert TransferFailed();
        } else {
            // too late to cancel for free: the clinic keeps the deposit
            uint256 providerPaid = _release(appointmentId);
            emit LateCancellation(appointmentId, providerPaid);
        }
        emit AppointmentCanceled(appointmentId, refunded);
    }

    function markNoShow(uint256 appointmentId) external {
        Appointment storage a = appointments[appointmentId];
        if (a.patient == address(0)) revert UnknownAppointment(appointmentId);
        if (msg.sender != a.provider) revert NotProvider(appointmentId);
        if (a.status != Status.Booked) revert InvalidStatus(appointmentId, Status.Booked, a.status);
        if (block.timestamp < a.slot) revert SlotInPast(a.slot);

        a.status = Status.NoShow;
        uint256 providerPaid = _release(appointmentId);
        emit AppointmentNoShow(appointmentId, providerPaid);
    }

    /// @dev Moves the deposit to the provider and the fee to the treasury.
    function _release(uint256 appointmentId) internal returns (uint256 providerPaid) {
        Appointment storage a = appointments[appointmentId];
        uint256 fee = (a.deposit * feeBps) / 10_000;
        providerPaid = a.deposit - fee;
        if (providerPaid > 0) {
            if (!paymentToken.transfer(a.provider, providerPaid)) revert TransferFailed();
        }
        if (fee > 0) {
            if (!paymentToken.approve(address(treasury), fee)) revert TransferFailed();
            treasury.receiveFees(fee);
        }
    }

    /* ==================== QUERIES ==================== */

    /// @notice True when this patient really visited this provider.
    function hasCompleted(address patient, address provider) external view returns (bool) {
        return completedVisits[patient][provider] > 0;
    }

    function appointmentsOf(address patient) external view returns (uint256[] memory) {
        return _byPatient[patient];
    }

    function appointmentsFor(address provider) external view returns (uint256[] memory) {
        return _byProvider[provider];
    }

    function appointmentCount() external view returns (uint256) {
        return appointments.length;
    }

    /* ==================== ADMIN ==================== */

    function setCancellationWindow(uint256 seconds_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        cancellationWindow = seconds_;
        emit WindowSet(seconds_);
    }

    function setFee(uint256 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > 1000) revert ZeroAmount();
        feeBps = bps;
        emit FeeSet(bps);
    }
}
