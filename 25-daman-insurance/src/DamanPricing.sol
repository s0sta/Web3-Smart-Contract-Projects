// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title DamanPricing
/// @notice The actuarial desk: premiums are quoted from a base rate per
///         insurance line, a risk-class multiplier and a coverage-band
///         multiplier — all adjustable by the operator.
library DamanLines {
    enum Line { None, Travel, FlightDelay, Property, Health }

    function label(Line l) internal pure returns (string memory) {
        if (l == Line.Travel) return "Travel";
        if (l == Line.FlightDelay) return "FlightDelay";
        if (l == Line.Property) return "Property";
        if (l == Line.Health) return "Health";
        return "None";
    }
}

contract DamanPricing {
    /// @notice Risk classes.
    enum RiskClass { Low, Standard, High }

    /// @notice Base annual rate (bps of the cover).
    mapping(DamanLines.Line line => uint256) public baseRateBps;

    /// @notice Risk-class multipliers (bps, 10_000 = 1x).
    mapping(RiskClass rc => uint256) public riskMultiplierBps;

    /// @notice Coverage-band multipliers: cover below the band gets the
    ///         multiplier (bps), defaulting to 10_000.
    mapping(DamanLines.Line line => uint256[]) public bandThresholds;
    mapping(DamanLines.Line line => uint256[]) public bandMultipliersBps;

    address public owner;

    event RateSet(DamanLines.Line line, uint256 bps);
    event RiskMultiplierSet(RiskClass rc, uint256 bps);
    event BandSet(DamanLines.Line line, uint256 threshold, uint256 multiplierBps);

    error ZeroAmount();
    error InvalidClass();

    constructor() {
        owner = msg.sender;
        baseRateBps[DamanLines.Line.Travel] = 300; // 3%
        baseRateBps[DamanLines.Line.FlightDelay] = 800; // 8%
        baseRateBps[DamanLines.Line.Property] = 150; // 1.5%
        baseRateBps[DamanLines.Line.Health] = 500; // 5%
        riskMultiplierBps[RiskClass.Low] = 7_000; // 0.7x
        riskMultiplierBps[RiskClass.Standard] = 10_000; // 1x
        riskMultiplierBps[RiskClass.High] = 16_000; // 1.6x
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero");
        owner = newOwner;
    }

    function setBaseRate(DamanLines.Line line, uint256 bps) external onlyOwner {
        if (bps > 10_000) revert ZeroAmount();
        baseRateBps[line] = bps;
        emit RateSet(line, bps);
    }

    function setRiskMultiplier(RiskClass rc, uint256 bps) external onlyOwner {
        riskMultiplierBps[rc] = bps;
        emit RiskMultiplierSet(rc, bps);
    }

    function addBand(DamanLines.Line line, uint256 threshold, uint256 multiplierBps) external onlyOwner {
        bandThresholds[line].push(threshold);
        bandMultipliersBps[line].push(multiplierBps);
        emit BandSet(line, threshold, multiplierBps);
    }

    /// @notice Quotes the premium for a cover amount and duration.
    function quote(
        DamanLines.Line line,
        RiskClass rc,
        uint256 cover,
        uint256 durationDays
    ) public view returns (uint256) {
        if (line == DamanLines.Line.None || cover == 0 || durationDays == 0) revert ZeroAmount();
        uint256 rate = baseRateBps[line];
        // band multiplier: the highest band the cover exceeds
        uint256 bandMult = 10_000;
        uint256[] storage thresholds = bandThresholds[line];
        uint256[] storage mults = bandMultipliersBps[line];
        for (uint256 i = 0; i < thresholds.length; i++) {
            if (cover >= thresholds[i]) bandMult = mults[i];
        }
        uint256 premium = (cover * rate / 10_000) * bandMult / 10_000;
        premium = premium * riskMultiplierBps[rc] / 10_000;
        // pro-rata for the duration (annual rate)
        premium = premium * durationDays / 365;
        return premium;
    }
}
