// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";

/// @title AtaaOracle
/// @notice The price feed for nisab computation: EMA-smoothed gold and silver
///         prices (per gram, 18 decimals). The zakat module derives the nisab
///         threshold in the payment token from these feeds.
contract AtaaOracle is AccessControl {
    /// @notice The operator posts prices.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR");

    struct Feed {
        uint128 ema;
        uint64 lastUpdate;
    }

    mapping(address asset => Feed) public feeds;

    /// @notice The gold and silver tokens (registered by the operator).
    address public goldToken;
    address public silverToken;

    uint256 public smoothingPeriod;
    uint256 public staleAfter;
    bool public paused;

    event PriceUpdated(address indexed asset, uint256 spot, uint256 ema);
    event AssetsSet(address gold, address silver);
    event SmoothingSet(uint256 period, uint256 staleAfter);
    event Paused(bool paused);

    error ZeroAddress();
    error ZeroAmount();
    error Stale(address asset, uint256 age);
    error FeedPaused();

    constructor(uint256 smoothingPeriod_, uint256 staleAfter_) {
        smoothingPeriod = smoothingPeriod_;
        staleAfter = staleAfter_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(GUARDIAN_ROLE, msg.sender);
    }

    function setAssets(address gold, address silver) external onlyRole(OPERATOR_ROLE) {
        if (gold == address(0) || silver == address(0)) revert ZeroAddress();
        goldToken = gold;
        silverToken = silver;
        emit AssetsSet(gold, silver);
    }

    function postPrice(address asset, uint256 spot) external onlyRole(OPERATOR_ROLE) {
        if (asset == address(0)) revert ZeroAddress();
        if (spot == 0) revert ZeroAmount();
        Feed storage f = feeds[asset];
        uint256 elapsed = f.lastUpdate == 0 ? smoothingPeriod : block.timestamp - f.lastUpdate;
        if (f.ema == 0) {
            f.ema = uint128(spot);
        } else {
            uint256 w = elapsed >= smoothingPeriod ? 1e18 : (elapsed * 1e18) / smoothingPeriod;
            f.ema = uint128((f.ema * (1e18 - w) + spot * w) / 1e18);
        }
        f.lastUpdate = uint64(block.timestamp);
        emit PriceUpdated(asset, spot, f.ema);
    }

    function price(address asset) external view returns (uint256) {
        return _price(asset);
    }

    function _price(address asset) internal view returns (uint256) {
        if (paused) revert FeedPaused();
        Feed storage f = feeds[asset];
        if (f.lastUpdate == 0) revert Stale(asset, type(uint256).max);
        uint256 age = block.timestamp - f.lastUpdate;
        if (age > staleAfter) revert Stale(asset, age);
        return f.ema;
    }

    /// @notice The gold nisab in the payment token: 85g × gold price.
    function goldNisab() external view returns (uint256) {
        return _price(goldToken) * 85;
    }

    /// @notice The silver nisab in the payment token: 595g × silver price.
    function silverNisab() external view returns (uint256) {
        return _price(silverToken) * 595;
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
