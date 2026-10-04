// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";

/// @title RahalaOracle
/// @notice The FX feed: EMA-smoothed exchange rates for the supported currency
///         pairs, with a staleness window and a guardian pause.
contract RahalaOracle is AccessControl {
    /// @notice The operator posts rate updates.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR");

    /// @notice One FX feed, keyed by the token address of the currency.
    struct Feed {
        uint128 ema; // rate vs the settlement stable, 18 decimals
        uint64 lastUpdate;
    }

    mapping(address currency => Feed) public feeds;

    uint256 public smoothingPeriod;
    uint256 public staleAfter;
    bool public paused;

    event RateUpdated(address indexed currency, uint256 spot, uint256 ema);
    event SmoothingSet(uint256 period, uint256 staleAfter);
    event Paused(bool paused);

    error ZeroAddress();
    error ZeroAmount();
    error Stale(address currency, uint256 age);
    error FeedPaused();

    constructor(uint256 smoothingPeriod_, uint256 staleAfter_) {
        smoothingPeriod = smoothingPeriod_;
        staleAfter = staleAfter_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(GUARDIAN_ROLE, msg.sender);
    }

    function postRate(address currency, uint256 spot) external onlyRole(OPERATOR_ROLE) {
        if (currency == address(0)) revert ZeroAddress();
        if (spot == 0) revert ZeroAmount();
        Feed storage f = feeds[currency];
        uint256 elapsed = f.lastUpdate == 0 ? smoothingPeriod : block.timestamp - f.lastUpdate;
        if (f.ema == 0) {
            f.ema = uint128(spot);
        } else {
            uint256 w = elapsed >= smoothingPeriod ? 1e18 : (elapsed * 1e18) / smoothingPeriod;
            f.ema = uint128((f.ema * (1e18 - w) + spot * w) / 1e18);
        }
        f.lastUpdate = uint64(block.timestamp);
        emit RateUpdated(currency, spot, f.ema);
    }

    function rate(address currency) external view returns (uint256) {
        if (paused) revert FeedPaused();
        Feed storage f = feeds[currency];
        if (f.lastUpdate == 0) revert Stale(currency, type(uint256).max);
        uint256 age = block.timestamp - f.lastUpdate;
        if (age > staleAfter) revert Stale(currency, age);
        return f.ema;
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
