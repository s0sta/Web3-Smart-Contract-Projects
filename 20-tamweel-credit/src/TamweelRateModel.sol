// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title TamweelRateModel
/// @notice The interest-rate math of the bank — a two-slope utilization curve:
///         a cheap base rate below the kink and a steeper slope above it, with a
///         reserve factor that routes part of the interest to the insurance fund.
///         Pure math, no state beyond parameters.
contract TamweelRateModel {
    /// @notice Curve parameters (per-second, 18-decimals).
    uint256 public baseRatePerSecond;
    uint256 public slope1PerSecond;
    uint256 public slope2PerSecond;
    uint256 public kink; // utilization bps where the curve steepens
    uint256 public reserveFactorBps;

    event ParamsSet(uint256 base, uint256 slope1, uint256 slope2, uint256 kink, uint256 reserveFactor);

    error ZeroAddress();
    error InvalidParams();

    address public owner;

    constructor(
        uint256 baseRatePerSecond_,
        uint256 slope1PerSecond_,
        uint256 slope2PerSecond_,
        uint256 kink_,
        uint256 reserveFactorBps_
    ) {
        owner = msg.sender;
        _set(baseRatePerSecond_, slope1PerSecond_, slope2PerSecond_, kink_, reserveFactorBps_);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    function _set(uint256 b, uint256 s1, uint256 s2, uint256 k, uint256 rf) internal {
        if (k > 10_000 || rf > 10_000) revert InvalidParams();
        baseRatePerSecond = b;
        slope1PerSecond = s1;
        slope2PerSecond = s2;
        kink = k;
        reserveFactorBps = rf;
        emit ParamsSet(b, s1, s2, k, rf);
    }

    function setParams(uint256 b, uint256 s1, uint256 s2, uint256 k, uint256 rf) external onlyOwner {
        _set(b, s1, s2, k, rf);
    }

    /// @notice The borrow rate at a given utilization (bps, per-second basis scaled).
    function borrowRatePerSecond(uint256 utilizationBps) public view returns (uint256) {
        if (utilizationBps <= kink) {
            return baseRatePerSecond + (slope1PerSecond * utilizationBps) / 10_000;
        }
        uint256 above = utilizationBps - kink;
        return baseRatePerSecond + (slope1PerSecond * kink) / 10_000 + (slope2PerSecond * above) / 10_000;
    }

    /// @notice The supply rate: borrowers' interest, minus the reserve factor.
    function supplyRatePerSecond(uint256 utilizationBps) public view returns (uint256) {
        uint256 borrow = borrowRatePerSecond(utilizationBps);
        uint256 gross = (borrow * utilizationBps) / 10_000;
        return (gross * (10_000 - reserveFactorBps)) / 10_000;
    }
}
