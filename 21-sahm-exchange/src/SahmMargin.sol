// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {SahmCollateral} from "./SahmCollateral.sol";
import {SahmOracle} from "./SahmOracle.sol";
import {SahmCompliance} from "./SahmCompliance.sol";
import {SahmRisk} from "./SahmRisk.sol";

/// @title SahmMargin
/// @notice The derivatives desk: leveraged long/short positions priced by the
///         oracle. Positions pay funding, realize PnL on close, and are liquidated
///         when their equity falls below the maintenance margin.
contract SahmMargin is AccessControl {
    /// @notice The operator manages leverage and funding.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR");

    /// @notice Position direction.
    enum Direction { None, Long, Short }

    /// @notice One position.
    struct Position {
        address trader;
        address token;
        Direction direction;
        uint256 margin; // locked margin backing the position
        uint256 notional; // position size in quote
        uint256 entryPrice;
        uint256 openedAt;
        uint256 lastFunding;
        bool open;
    }

    Position[] public positions;
    mapping(address trader => uint256[]) public positionsOf;

    uint256 public maxLeverageBps; // e.g. 500 = 5x
    uint256 public maintenanceMarginBps; // e.g. 100 = 1%
    uint256 public fundingRatePerSecond;
    uint256 public liquidationBonusBps;

    SahmCollateral public immutable collateral;
    SahmOracle public immutable oracle;
    SahmCompliance public immutable compliance;
    SahmRisk public immutable risk;

    event PositionOpened(uint256 indexed positionId, address indexed trader, address token, Direction direction, uint256 margin, uint256 notional);
    event PositionClosed(uint256 indexed positionId, int256 pnl);
    event PositionLiquidated(uint256 indexed positionId, address indexed liquidator, uint256 bonus);
    event FundingCharged(uint256 indexed positionId, uint256 amount);
    event ParamsSet(uint256 maxLeverageBps, uint256 maintenanceMarginBps, uint256 fundingRatePerSecond);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownPosition(uint256 positionId);
    error PositionAlreadyClosed(uint256 positionId);
    error NotTrader(uint256 positionId);
    error InvalidDirection();
    error LeverageLimit(uint256 leverageBps, uint256 maxBps);
    error BelowMaintenance(uint256 equityBps, uint256 requiredBps);
    error TransferFailed();

    constructor(
        SahmCollateral collateral_,
        SahmOracle oracle_,
        SahmCompliance compliance_,
        SahmRisk risk_
    ) {
        if (address(collateral_) == address(0) || address(oracle_) == address(0) || address(compliance_) == address(0) || address(risk_) == address(0)) {
            revert ZeroAddress();
        }
        collateral = collateral_;
        oracle = oracle_;
        compliance = compliance_;
        risk = risk_;
        maxLeverageBps = 500; // 5x
        maintenanceMarginBps = 100; // 1%
        fundingRatePerSecond = 0; // funding disabled by default
        liquidationBonusBps = 500; // 5% of the position margin
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    /* ==================== OPEN ==================== */

    function openPosition(address token, Direction direction, uint256 margin, uint256 leverageBps) external returns (uint256 positionId) {
        if (token == address(0)) revert ZeroAddress();
        if (direction == Direction.None) revert InvalidDirection();
        if (!compliance.canTrade(msg.sender)) revert();
        if (margin == 0 || leverageBps == 0) revert ZeroAmount();
        if (leverageBps > maxLeverageBps) revert LeverageLimit(leverageBps, maxLeverageBps);

        uint256 notional = (margin * leverageBps) / 100;
        risk.validatePosition(token, msg.sender, notional);

        // the margin is locked in the collateral desk
        collateral.lockMargin(msg.sender, margin);

        positionId = positions.length;
        positions.push();
        Position storage p = positions[positionId];
        p.trader = msg.sender;
        p.token = token;
        p.direction = direction;
        p.margin = margin;
        p.notional = notional;
        p.entryPrice = oracle.price(token);
        p.openedAt = block.timestamp;
        p.lastFunding = block.timestamp;
        p.open = true;
        positionsOf[msg.sender].push(positionId);
        emit PositionOpened(positionId, msg.sender, token, direction, margin, notional);
    }

    /* ==================== PnL & FUNDING ==================== */

    function _pnl(Position storage p, uint256 currentPrice) internal view returns (int256) {
        if (p.direction == Direction.Long) {
            int256 delta = int256(currentPrice) - int256(p.entryPrice);
            return (delta * int256(p.notional)) / int256(p.entryPrice);
        } else {
            int256 delta = int256(p.entryPrice) - int256(currentPrice);
            return (delta * int256(p.notional)) / int256(p.entryPrice);
        }
    }

    function equity(Position storage p, uint256 currentPrice) internal view returns (int256) {
        return int256(p.margin) + _pnl(p, currentPrice) - int256(fundingOwed(p));
    }

    function fundingOwed(Position storage p) internal view returns (uint256) {
        uint256 elapsed = block.timestamp - p.lastFunding;
        return (p.notional * fundingRatePerSecond * elapsed) / 1e18;
    }

    function equityBps(uint256 positionId) public view returns (uint256) {
        Position storage p = positions[positionId];
        if (p.notional == 0) return 0;
        uint256 price = oracle.price(p.token);
        int256 eq = equity(p, price);
        if (eq <= 0) return 0;
        return (uint256(eq) * 10_000) / p.notional;
    }

    /* ==================== CLOSE & LIQUIDATE ==================== */

    function closePosition(uint256 positionId) external {
        Position storage p = positions[positionId];
        if (p.trader == address(0)) revert UnknownPosition(positionId);
        if (msg.sender != p.trader) revert NotTrader(positionId);
        if (!p.open) revert PositionAlreadyClosed(positionId);

        uint256 price = oracle.price(p.token);
        int256 pnl = _pnl(p, price);
        uint256 funding = fundingOwed(p);
        int256 net = pnl - int256(funding);

        collateral.unlockMargin(p.trader, p.margin);
        p.open = false;

        if (net > 0) {
            // profit: pay the trader from the collateral desk's pool
            collateral.payOut(p.trader, uint256(net));
        } else if (net < 0) {
            // loss: burn the trader's margin (socialized to the pool)
            collateral.burnMargin(p.trader, uint256(-net));
        }
        if (funding > 0) {
            collateral.burnMargin(p.trader, funding);
        }
        emit PositionClosed(positionId, net);
    }

    /// @notice Liquidates a position whose equity is below maintenance margin;
    ///         the liquidator receives a bonus taken from the remaining margin.
    function liquidate(uint256 positionId) external {
        Position storage p = positions[positionId];
        if (p.trader == address(0)) revert UnknownPosition(positionId);
        if (!p.open) revert PositionAlreadyClosed(positionId);

        uint256 price = oracle.price(p.token);
        if (equityBps(positionId) >= maintenanceMarginBps) {
            revert BelowMaintenance(equityBps(positionId), maintenanceMarginBps);
        }

        int256 net = _pnl(p, price) - int256(fundingOwed(p));
        collateral.unlockMargin(p.trader, p.margin);
        p.open = false;

        // the bonus to the liquidator is carved from whatever margin survives
        uint256 bonus = (p.margin * liquidationBonusBps) / 10_000;
        if (bonus > 0) {
            collateral.payOut(msg.sender, bonus);
        }
        if (net < 0) {
            collateral.burnMargin(p.trader, uint256(-net));
        }
        emit PositionLiquidated(positionId, msg.sender, bonus);
    }

    /* ==================== ADMIN ==================== */

    function setParams(uint256 maxLeverageBps_, uint256 maintenanceBps_, uint256 fundingPerSecond_) external onlyRole(OPERATOR_ROLE) {
        if (maxLeverageBps_ == 0 || maintenanceBps_ > 5000) revert ZeroAmount();
        maxLeverageBps = maxLeverageBps_;
        maintenanceMarginBps = maintenanceBps_;
        fundingRatePerSecond = fundingPerSecond_;
        emit ParamsSet(maxLeverageBps_, maintenanceBps_, fundingPerSecond_);
    }
}
