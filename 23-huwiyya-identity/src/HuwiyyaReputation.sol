// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HuwiyyaAttestations} from "./HuwiyyaAttestations.sol";
import {Checkpoints} from "./lib/Checkpoints.sol";

/// @title HuwiyyaReputation
/// @notice The reputation engine: a DID's score is the weighted sum of its live
///         attestations with daily time decay, mapped to named bands and
///         checkpointed for governance voting.
contract HuwiyyaReputation {
    using Checkpoints for Checkpoints.Checkpoint[];

    /// @notice Score bands (minimum score → band name).
    uint256[] public bandMinimums;
    string[] public bandNames;

    /// @notice Daily decay applied to each attestation's contribution (bps).
    uint256 public decayPerDayBps;

    /// @notice Total attestations consulted (for weight normalization).
    uint256 public attestationCount;

    HuwiyyaAttestations public immutable attestations;

    mapping(address did => Checkpoints.Checkpoint[]) private _scores;

    address public owner;

    event ScoreUpdated(address indexed did, uint256 score);
    event BandSet(uint256 min, string name);
    event DecaySet(uint256 bps);

    error ZeroAddress();
    error ZeroAmount();

    constructor(HuwiyyaAttestations attestations_) {
        if (address(attestations_) == address(0)) revert ZeroAddress();
        owner = msg.sender;
        attestations = attestations_;
        decayPerDayBps = 50; // 0.5% per day
        bandMinimums.push(0);
        bandNames.push("New");
        bandMinimums.push(600);
        bandNames.push("Verified");
        bandMinimums.push(850);
        bandNames.push("Trusted");
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    /* ==================== COMPUTATION ==================== */

    /// @notice The live score: Σ (attestation score × type weight × attestor
    ///         weight × decay), normalized to 0–1000.
    function scoreOf(address did) public view returns (uint256) {
        uint256[] memory ids = attestations.attestationsOfList(did);
        uint256 weighted = 0;
        uint256 weightSum = 0;
        for (uint256 i = 0; i < ids.length; i++) {
            ( , address attestor, uint8 attType, uint16 score, uint64 expiresAt, , bool revoked) = attestations.attestations(ids[i]);
            if (revoked) continue;
            if (expiresAt != 0 && block.timestamp > expiresAt) continue;
            uint256 daysOld = 0;
            // decay anchored to the expiry or, if perpetual, not applied
            if (expiresAt != 0) {
                uint64 issuedEstimate = expiresAt - 365 days;
                if (block.timestamp > issuedEstimate) daysOld = (block.timestamp - issuedEstimate) / 1 days;
            }
            uint256 decay = 10_000 - (daysOld * decayPerDayBps > 10_000 ? 10_000 : daysOld * decayPerDayBps);
            uint256 typeW = attestations.typeWeightBps(attType);
            uint256 attW = attestations.weightBps(attestor);
            if (attW == 0) attW = 10_000; // unlisted attestors count fully
            uint256 contribution = (uint256(score) * typeW / 10_000) * attW / 10_000 * decay / 10_000;
            weighted += contribution;
            weightSum += (typeW * attW / 10_000) * decay / 10_000;
        }
        if (weighted == 0) return 0;
        return weightSum == 0 ? 0 : weighted / (weightSum / 10_000 + 1);
    }

    /// @notice Records a fresh score checkpoint (called after attestation events).
    function checkpoint(address did) external {
        uint256 score = scoreOf(did);
        _scores[did].write(_scores[did].latest(), score);
        emit ScoreUpdated(did, score);
    }

    function getPastScore(address did, uint256 blockNumber) external view returns (uint256) {
        return _scores[did].lookup(blockNumber);
    }

    /// @notice The named band for a live score.
    function bandOf(uint256 score) public view returns (string memory) {
        string memory best = bandNames[0];
        for (uint256 i = 0; i < bandMinimums.length; i++) {
            if (score >= bandMinimums[i]) best = bandNames[i];
        }
        return best;
    }

    /* ==================== ADMIN ==================== */

    function setDecay(uint256 bps) external onlyOwner {
        if (bps > 10_000) revert ZeroAmount();
        decayPerDayBps = bps;
        emit DecaySet(bps);
    }

    function addBand(uint256 min, string calldata name) external onlyOwner {
        bandMinimums.push(min);
        bandNames.push(name);
        emit BandSet(min, name);
    }
}
