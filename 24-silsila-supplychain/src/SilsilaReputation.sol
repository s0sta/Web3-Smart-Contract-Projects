// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SilsilaRegistry} from "./SilsilaRegistry.sol";
import {SilsilaShipments} from "./SilsilaShipments.sol";
import {SilsilaQuality} from "./SilsilaQuality.sol";
import {Checkpoints} from "./lib/Checkpoints.sol";

/// @title SilsilaReputation
/// @notice The performance engine: every entity earns a 0–1000 score from its
///         on-time delivery rate and its average inspection grade, with daily
///         decay toward the neutral 500. Scores feed the governor.
contract SilsilaReputation {
    using Checkpoints for Checkpoints.Checkpoint[];

    SilsilaRegistry public immutable registry;
    SilsilaShipments public immutable shipments;
    SilsilaQuality public immutable quality;

    uint256 public decayPerDayBps;

    mapping(address entity => Checkpoints.Checkpoint[]) private _scores;

    /// @notice Rolling stats per entity.
    mapping(address entity => uint256) public deliveredCount;
    mapping(address entity => uint256) public onTimeCount;
    mapping(address entity => uint256) public gradeSum;
    mapping(address entity => uint256) public gradeCount;
    mapping(address entity => uint256) public lastUpdate;

    address public owner;

    event ScoreUpdated(address indexed entity, uint256 score);
    event DeliveryRecorded(address indexed entity, bool onTime);
    event GradeRecorded(address indexed entity, uint8 grade);
    event DecaySet(uint256 bps);

    error ZeroAddress();
    error ZeroAmount();

    constructor(SilsilaRegistry registry_, SilsilaShipments shipments_, SilsilaQuality quality_) {
        if (address(registry_) == address(0) || address(shipments_) == address(0) || address(quality_) == address(0)) {
            revert ZeroAddress();
        }
        owner = msg.sender;
        registry = registry_;
        shipments = shipments_;
        quality = quality_;
        decayPerDayBps = 20; // 0.2% per day
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    /* ==================== RECORDING ==================== */

    /// @notice Recorded by the payments desk when a shipment is delivered.
    function recordDelivery(address carrier, bool onTime) external {
        if (msg.sender != owner && msg.sender != address(shipments)) revert();
        deliveredCount[carrier] += 1;
        if (onTime) onTimeCount[carrier] += 1;
        emit DeliveryRecorded(carrier, onTime);
        checkpoint(carrier);
    }

    /// @notice Recorded when an inspection is resolved.
    function recordGrade(address supplier, uint8 grade) external {
        if (msg.sender != owner && msg.sender != address(quality)) revert();
        gradeSum[supplier] += grade;
        gradeCount[supplier] += 1;
        emit GradeRecorded(supplier, grade);
        checkpoint(supplier);
    }

    /* ==================== SCORING ==================== */

    function scoreOf(address entity) public view returns (uint256) {
        uint256 delivered = deliveredCount[entity];
        uint256 graded = gradeCount[entity];
        if (delivered == 0 && graded == 0) return 500; // neutral start

        uint256 total = 0;
        uint256 weight = 0;
        if (delivered > 0) {
            uint256 onTime = (onTimeCount[entity] * 1000) / delivered; // 0–1000
            total += onTime * 5;
            weight += 5;
        }
        if (graded > 0) {
            uint256 avgGrade = (gradeSum[entity] * 10) / graded; // 0–1000
            total += avgGrade * 5;
            weight += 5;
        }
        uint256 score = total / weight;
        // decay toward the neutral 500
        uint256 elapsedDays = lastUpdate[entity] == 0 ? 0 : (block.timestamp - lastUpdate[entity]) / 1 days;
        if (elapsedDays > 0) {
            uint256 decay = elapsedDays * decayPerDayBps > 10_000 ? 10_000 : elapsedDays * decayPerDayBps;
            score = (score * (10_000 - decay) + 500 * decay) / 10_000;
        }
        return score;
    }

    function checkpoint(address entity) public {
        _scores[entity].write(_scores[entity].latest(), scoreOf(entity));
        lastUpdate[entity] = block.timestamp;
        emit ScoreUpdated(entity, scoreOf(entity));
    }

    function getPastScore(address entity, uint256 blockNumber) external view returns (uint256) {
        return _scores[entity].lookup(blockNumber);
    }

    function setDecay(uint256 bps) external onlyOwner {
        if (bps > 10_000) revert ZeroAmount();
        decayPerDayBps = bps;
        emit DecaySet(bps);
    }
}
