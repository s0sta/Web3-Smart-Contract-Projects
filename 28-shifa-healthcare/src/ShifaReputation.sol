// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ShifaRegistry} from "./ShifaRegistry.sol";
import {ShifaAppointments} from "./ShifaAppointments.sol";
import {Checkpoints} from "./lib/Checkpoints.sol";

/// @title ShifaReputation
/// @notice Trust for doctors and clinics. A patient can rate a provider only
///         after a completed visit, so scores cannot be bought with fresh
///         wallets. The score is a 0–1000 number that starts at 500 for everyone
///         and drifts back toward 500 when a provider is inactive.
contract ShifaReputation {
    using Checkpoints for Checkpoints.Checkpoint[];

    ShifaRegistry public immutable registry;
    ShifaAppointments public immutable appointments;

    uint256 public decayPerDayBps;

    mapping(address provider => Checkpoints.Checkpoint[]) private _scores;
    mapping(address provider => uint256) public ratingSum;
    mapping(address provider => uint256) public ratingCount;
    mapping(address provider => uint256) public lastUpdate;
    mapping(uint256 appointmentId => bool) public rated;

    address public owner;

    event Rated(uint256 indexed appointmentId, address indexed provider, address indexed patient, uint8 score);
    event ScoreUpdated(address indexed provider, uint256 score);
    event DecaySet(uint256 bps);

    error ZeroAddress();
    error ZeroAmount();
    error NotPatientOfVisit(address patient, address provider);
    error AlreadyRated(uint256 appointmentId);
    error InvalidScore(uint8 score);

    constructor(ShifaRegistry registry_, ShifaAppointments appointments_) {
        if (address(registry_) == address(0) || address(appointments_) == address(0)) revert ZeroAddress();
        owner = msg.sender;
        registry = registry_;
        appointments = appointments_;
        decayPerDayBps = 20; // 0.2% per day back toward neutral
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    /* ==================== RATING ==================== */

    /// @notice After a completed visit the patient rates the provider 0–100.
    function rate(uint256 appointmentId, uint8 score) external {
        if (score > 100) revert InvalidScore(score);
        if (rated[appointmentId]) revert AlreadyRated(appointmentId);

        (address patient, address provider, , , ShifaAppointments.Status status, ) = appointments.appointments(appointmentId);
        if (patient == address(0)) revert NotPatientOfVisit(msg.sender, provider);
        if (msg.sender != patient) revert NotPatientOfVisit(msg.sender, provider);
        if (status != ShifaAppointments.Status.Completed) revert NotPatientOfVisit(msg.sender, provider);

        rated[appointmentId] = true;
        ratingSum[provider] += score;
        ratingCount[provider] += 1;
        checkpoint(provider);
        emit Rated(appointmentId, provider, patient, score);
    }

    /* ==================== SCORING ==================== */

    /// @notice 0–1000. No ratings yet means the neutral 500.
    function scoreOf(address provider) public view returns (uint256) {
        uint256 count = ratingCount[provider];
        if (count == 0) return 500;

        uint256 average = (ratingSum[provider] * 10) / count; // 0–1000
        count = count > 100 ? 100 : count;
        // the score is the average, pulled toward 500 when few ratings exist
        uint256 confidence = (count * 10_000) / 100;
        uint256 score = (average * confidence + 500 * (10_000 - confidence)) / 10_000;

        uint256 elapsedDays = lastUpdate[provider] == 0 ? 0 : (block.timestamp - lastUpdate[provider]) / 1 days;
        if (elapsedDays > 0) {
            uint256 decay = elapsedDays * decayPerDayBps > 10_000 ? 10_000 : elapsedDays * decayPerDayBps;
            score = (score * (10_000 - decay) + 500 * decay) / 10_000;
        }
        return score;
    }

    function checkpoint(address provider) public {
        _scores[provider].write(_scores[provider].latest(), scoreOf(provider));
        lastUpdate[provider] = block.timestamp;
        emit ScoreUpdated(provider, scoreOf(provider));
    }

    function getPastScore(address provider, uint256 blockNumber) external view returns (uint256) {
        return _scores[provider].lookup(blockNumber);
    }

    function setDecay(uint256 bps) external onlyOwner {
        if (bps > 10_000) revert ZeroAmount();
        decayPerDayBps = bps;
        emit DecaySet(bps);
    }
}
