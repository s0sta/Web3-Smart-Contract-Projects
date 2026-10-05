// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";

/// @title DamanOracle
/// @notice The data engine: EMA-smoothed price feeds plus a parametric
///         condition registry — the operator posts measurements (price moves,
///         delays, temperatures) and conditions are evaluated on demand by the
///         parametric desk.
contract DamanOracle is AccessControl {
    /// @notice The operator posts updates and conditions.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR");

    /// @notice Condition kinds.
    enum CondType { PriceAbove, PriceBelow, MeasurementAbove, MeasurementBelow }

    /// @notice One parametric condition.
    struct Condition {
        address token; // asset for price conditions, 0 for measurements
        CondType condType;
        uint256 threshold;
        uint64 lastUpdated;
        bool active;
    }

    Condition[] public conditions;

    /// @notice EMA feeds.
    struct Feed {
        uint128 ema;
        uint64 lastUpdate;
    }

    mapping(address token => Feed) public feeds;

    /// @notice Latest measurement per measurement id (e.g. "flight AE123 delay").
    mapping(bytes32 measurementId => uint256) public measurements;
    mapping(bytes32 measurementId => uint64) public measuredAt;

    uint256 public smoothingPeriod;
    uint256 public staleAfter;
    bool public paused;

    event PriceUpdated(address indexed token, uint256 spot, uint256 ema);
    event MeasurementPosted(bytes32 indexed measurementId, uint256 value);
    event ConditionAdded(uint256 indexed conditionId, CondType condType, uint256 threshold);
    event ConditionSet(uint256 indexed conditionId, bool active);
    event SmoothingSet(uint256 period, uint256 staleAfter);
    event Paused(bool paused);

    error ZeroAddress();
    error ZeroAmount();
    error Stale(address token, uint256 age);
    error FeedPaused();
    error UnknownCondition(uint256 conditionId);

    constructor(uint256 smoothingPeriod_, uint256 staleAfter_) {
        smoothingPeriod = smoothingPeriod_;
        staleAfter = staleAfter_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(GUARDIAN_ROLE, msg.sender);
    }

    /* ==================== FEEDS ==================== */

    function postPrice(address token, uint256 spot) external onlyRole(OPERATOR_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (spot == 0) revert ZeroAmount();
        Feed storage f = feeds[token];
        uint256 elapsed = f.lastUpdate == 0 ? smoothingPeriod : block.timestamp - f.lastUpdate;
        if (f.ema == 0) {
            f.ema = uint128(spot);
        } else {
            uint256 w = elapsed >= smoothingPeriod ? 1e18 : (elapsed * 1e18) / smoothingPeriod;
            f.ema = uint128((f.ema * (1e18 - w) + spot * w) / 1e18);
        }
        f.lastUpdate = uint64(block.timestamp);
        emit PriceUpdated(token, spot, f.ema);
    }

    function price(address token) external view returns (uint256) {
        if (paused) revert FeedPaused();
        Feed storage f = feeds[token];
        if (f.lastUpdate == 0) revert Stale(token, type(uint256).max);
        uint256 age = block.timestamp - f.lastUpdate;
        if (age > staleAfter) revert Stale(token, age);
        return f.ema;
    }

    /* ==================== MEASUREMENTS & CONDITIONS ==================== */

    function postMeasurement(bytes32 measurementId, uint256 value) external onlyRole(OPERATOR_ROLE) {
        measurements[measurementId] = value;
        measuredAt[measurementId] = uint64(block.timestamp);
        emit MeasurementPosted(measurementId, value);
    }

    function addCondition(address token, CondType condType, uint256 threshold) external onlyRole(OPERATOR_ROLE) returns (uint256 conditionId) {
        if (threshold == 0) revert ZeroAmount();
        conditionId = conditions.length;
        conditions.push();
        Condition storage c = conditions[conditionId];
        c.token = token;
        c.condType = condType;
        c.threshold = threshold;
        c.active = true;
        c.lastUpdated = uint64(block.timestamp);
        emit ConditionAdded(conditionId, condType, threshold);
    }

    function setConditionActive(uint256 conditionId, bool active) external onlyRole(OPERATOR_ROLE) {
        if (conditionId >= conditions.length) revert UnknownCondition(conditionId);
        conditions[conditionId].active = active;
        emit ConditionSet(conditionId, active);
    }

    /// @notice Evaluates a condition against the current data.
    function checkCondition(uint256 conditionId) external view returns (bool) {
        if (conditionId >= conditions.length) revert UnknownCondition(conditionId);
        Condition storage c = conditions[conditionId];
        if (!c.active) return false;
        uint256 value;
        if (c.condType == CondType.PriceAbove || c.condType == CondType.PriceBelow) {
            Feed storage f = feeds[c.token];
            if (f.lastUpdate == 0) return false;
            uint256 age = block.timestamp - f.lastUpdate;
            if (age > staleAfter) return false;
            value = f.ema;
        } else {
            // measurement conditions reference the condition id itself
            value = measurements[bytes32(uint256(conditionId))];
        }
        if (c.condType == CondType.PriceAbove || c.condType == CondType.MeasurementAbove) {
            return value > c.threshold;
        }
        return value < c.threshold;
    }

    function setSmoothing(uint256 smoothingPeriod_, uint256 staleAfter_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (smoothingPeriod_ == 0 || staleAfter_ == 0) revert ZeroAmount();
        smoothingPeriod = smoothingPeriod_;
        staleAfter = staleAfter_;
        emit SmoothingSet(smoothingPeriod_, staleAfter_);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        paused = true;
        emit Paused(true);
    }

    function unpause() external onlyRole(GUARDIAN_ROLE) {
        paused = false;
        emit Paused(false);
    }
}
