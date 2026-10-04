// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {SahmOracle} from "./SahmOracle.sol";

/// @title SahmRisk
/// @notice The exchange's risk engine: per-market position limits, rolling
///         volume caps and circuit breakers that halt trading when a price moves
///         beyond the band between consecutive updates.
contract SahmRisk is AccessControl {
    /// @notice The operator manages risk parameters.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR");

    /// @notice Which contracts may consult/record (the trading venues).
    bytes32 public constant VENUE_ROLE = keccak256("VENUE");

    SahmOracle public immutable oracle;

    /// @notice Per-market risk parameters.
    struct MarketRisk {
        uint256 maxPosition; // max open notional per trader
        uint256 maxDailyVolume; // rolling 24h cap
        uint256 maxMoveBps; // circuit breaker: max price move between updates
        bool halted;
    }

    mapping(address token => MarketRisk) public risks;

    mapping(address token => uint256) public dailyVolume;
    mapping(address token => uint256) public lastVolumeWindow;

    event RiskSet(address indexed token, uint256 maxPosition, uint256 maxDailyVolume, uint256 maxMoveBps);
    event MarketHalted(address indexed token, bool halted);
    event CircuitBroken(address indexed token, uint256 prev, uint256 next);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownMarket(address token);
    error MarketHaltedError(address token);
    error CircuitBrokenError(address token, uint256 moveBps);
    error PositionLimit(uint256 notional, uint256 cap);
    error VolumeLimitError(uint256 used, uint256 cap);

    constructor(SahmOracle oracle_) {
        if (address(oracle_) == address(0)) revert ZeroAddress();
        oracle = oracle_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    function setMarket(address token, uint256 maxPosition, uint256 maxDailyVolume, uint256 maxMoveBps) external onlyRole(OPERATOR_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (maxPosition == 0 || maxDailyVolume == 0 || maxMoveBps == 0) revert ZeroAmount();
        risks[token] = MarketRisk({
            maxPosition: maxPosition,
            maxDailyVolume: maxDailyVolume,
            maxMoveBps: maxMoveBps,
            halted: false
        });
        emit RiskSet(token, maxPosition, maxDailyVolume, maxMoveBps);
    }

    function haltMarket(address token, bool halted) external onlyRole(OPERATOR_ROLE) {
        risks[token].halted = halted;
        emit MarketHalted(token, halted);
    }

    /// @notice Checks the latest move against the band; trips the breaker if needed.
    /// @dev The halt must persist, so this never reverts — venues consult the
    ///      halted flag before accepting new activity.
    function checkMove(address token, uint256 prevPrice, uint256 nextPrice) external returns (bool) {
        MarketRisk storage r = risks[token];
        if (r.maxPosition == 0) revert UnknownMarket(token);
        if (r.halted) return false;
        if (prevPrice == 0 || nextPrice == 0) return true;
        uint256 moveBps = prevPrice > nextPrice
            ? ((prevPrice - nextPrice) * 10_000) / prevPrice
            : ((nextPrice - prevPrice) * 10_000) / prevPrice;
        if (moveBps > r.maxMoveBps) {
            r.halted = true;
            emit CircuitBroken(token, prevPrice, nextPrice);
            return false;
        }
        return true;
    }

    /// @notice Validates an order's notional against the market's position cap.
    function validatePosition(address token, address trader, uint256 newNotional) external view {
        MarketRisk storage r = risks[token];
        if (r.maxPosition == 0) revert UnknownMarket(token);
        if (r.halted) revert MarketHaltedError(token);
        if (newNotional > r.maxPosition) revert PositionLimit(newNotional, r.maxPosition);
        trader; // reserved for per-trader caps
    }

    /// @notice Records traded volume and enforces the rolling 24h cap.
    function recordVolume(address token, uint256 amount) external onlyRole(VENUE_ROLE) {
        MarketRisk storage r = risks[token];
        if (r.maxPosition == 0) revert UnknownMarket(token);
        uint256 window = block.timestamp / 1 days;
        if (lastVolumeWindow[token] != window) {
            lastVolumeWindow[token] = window;
            dailyVolume[token] = 0;
        }
        uint256 used = dailyVolume[token] + amount;
        if (used > r.maxDailyVolume) revert VolumeLimitError(used, r.maxDailyVolume);
        dailyVolume[token] = used;
    }
}
