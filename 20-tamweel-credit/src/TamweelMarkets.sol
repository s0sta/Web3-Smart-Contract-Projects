// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";
import {AccessControl} from "./AccessControl.sol";
import {TamweelVault} from "./TamweelVault.sol";
import {TamweelOracle} from "./TamweelOracle.sol";
import {TamweelRateModel} from "./TamweelRateModel.sol";
import {TamweelCompliance} from "./TamweelCompliance.sol";
import {TamweelCollateral} from "./TamweelCollateral.sol";

/// @title TamweelMarkets
/// @notice The collateralized lending desk: borrowers supply an accepted collateral
///         asset, borrow the payment stable against its LTV, and stay solvent while
///         their health factor stays above 1. Interest accrues per second through
///         global borrow/supply indices; liquidators close unhealthy positions.
contract TamweelMarkets is AccessControl {
    /// @notice The operator: lists markets, adjusts parameters.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR");

    /// @notice One collateral market.
    struct Market {
        IERC20 collateralToken;
        uint256 ltvBps; // max borrow / collateral value
        uint256 liquidationThresholdBps; // health < 1 beyond this
        uint256 liquidationBonusBps; // bonus to liquidators
        bool active;
    }

    mapping(uint256 marketId => Market) public markets;
    uint256 public marketCount;

    /// @notice Per-market per-user positions.
    mapping(uint256 marketId => mapping(address user => uint256)) public collateral;
    mapping(uint256 marketId => mapping(address user => uint256)) public debt;

    /// @notice Global accrued interest (per-second, compounded indices).
    mapping(uint256 marketId => uint256) public borrowIndex; // scaled 1e27
    mapping(uint256 marketId => uint256) public supplyIndex; // scaled 1e27
    mapping(uint256 marketId => uint256) public lastAccrual;
    mapping(uint256 marketId => mapping(address user => uint256)) public userBorrowIndex;
    mapping(uint256 marketId => mapping(address user => uint256)) public userSupplyIndex;

    /// @notice The market's outstanding debt and the vault's total supplied.
    uint256 public totalDebt;
    uint256 public totalSupplied;

    TamweelVault public immutable vault;
    TamweelOracle public immutable oracle;
    TamweelRateModel public immutable rateModel;
    TamweelCompliance public immutable compliance;
    TamweelCollateral public immutable collateralRegistry;
    IERC20 public immutable debtToken; // the stable

    event MarketListed(uint256 indexed marketId, address collateralToken, uint256 ltvBps);
    event Supplied(uint256 indexed marketId, address indexed user, uint256 amount);
    event Withdrawn(uint256 indexed marketId, address indexed user, uint256 amount);
    event Borrowed(uint256 indexed marketId, address indexed user, uint256 amount);
    event Repaid(uint256 indexed marketId, address indexed user, uint256 amount);
    event Liquidated(uint256 indexed marketId, address indexed user, address indexed liquidator, uint256 debt, uint256 collateralSeized);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownMarket(uint256 marketId);
    error MarketInactive(uint256 marketId);
    error Unhealthy(uint256 health);
    error InsufficientDebt(uint256 debt, uint256 amount);
    error TransferFailed();

    constructor(
        TamweelVault vault_,
        TamweelOracle oracle_,
        TamweelRateModel rateModel_,
        TamweelCompliance compliance_,
        TamweelCollateral collateralRegistry_,
        IERC20 debtToken_
    ) {
        if (address(vault_) == address(0) || address(oracle_) == address(0) || address(rateModel_) == address(0) || address(compliance_) == address(0) || address(collateralRegistry_) == address(0) || address(debtToken_) == address(0)) {
            revert ZeroAddress();
        }
        vault = vault_;
        oracle = oracle_;
        rateModel = rateModel_;
        compliance = compliance_;
        collateralRegistry = collateralRegistry_;
        debtToken = debtToken_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    /* ==================== MARKETS ==================== */

    function listMarket(IERC20 collateralToken, uint256 ltvBps, uint256 liquidationThresholdBps, uint256 liquidationBonusBps) external onlyRole(OPERATOR_ROLE) returns (uint256 marketId) {
        if (address(collateralToken) == address(0)) revert ZeroAddress();
        if (ltvBps == 0 || liquidationThresholdBps == 0 || liquidationBonusBps == 0) revert ZeroAmount();
        marketId = marketCount++;
        markets[marketId] = Market({
            collateralToken: collateralToken,
            ltvBps: ltvBps,
            liquidationThresholdBps: liquidationThresholdBps,
            liquidationBonusBps: liquidationBonusBps,
            active: true
        });
        borrowIndex[marketId] = 1e18;
        supplyIndex[marketId] = 1e18;
        lastAccrual[marketId] = block.timestamp;
        emit MarketListed(marketId, address(collateralToken), ltvBps);
    }

    /* ==================== ACCRUAL ==================== */

    /// @notice Compounds interest since the last accrual.
    function accrueInterest(uint256 marketId) public returns (uint256 utilizationBps) {
        uint256 elapsed = block.timestamp - lastAccrual[marketId];
        if (elapsed == 0) return utilization(0);
        uint256 util = utilization(totalDebt);
        utilizationBps = util;
        uint256 borrowRate = rateModel.borrowRatePerSecond(util);
        uint256 factor = borrowRate * elapsed; // fraction × 1e18
        borrowIndex[marketId] = borrowIndex[marketId] * (1e18 + factor) / 1e18;

        uint256 supplyRate = rateModel.supplyRatePerSecond(util);
        uint256 supplyFactor = supplyRate * elapsed;
        supplyIndex[marketId] = supplyIndex[marketId] * (1e18 + supplyFactor) / 1e18;
        lastAccrual[marketId] = block.timestamp;

        // growth of debt: totalDebt scaled by the borrow factor
        totalDebt = totalDebt * (1e18 + factor) / 1e18;
    }

    function utilization(uint256 debt) public view returns (uint256 bps) {
        uint256 total = totalSupplied;
        if (total == 0) return 0;
        return (debt * 10_000) / total;
    }

    /* ==================== SUPPLY & BORROW ==================== */

    function supply(uint256 marketId, uint256 amount) external {
        Market storage m = markets[marketId];
        if (m.ltvBps == 0) revert UnknownMarket(marketId);
        if (!m.active) revert MarketInactive(marketId);
        if (!compliance.canTransact(msg.sender)) revert();
        accrueInterest(marketId);

        userSupplyIndex[marketId][msg.sender] = supplyIndex[marketId];
        collateral[marketId][msg.sender] += amount;
        if (!m.collateralToken.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        emit Supplied(marketId, msg.sender, amount);
    }

    /// @notice Borrows the stable against collateral; the vault funds the position.
    function borrow(uint256 marketId, uint256 amount) external {
        Market storage m = markets[marketId];
        if (m.ltvBps == 0) revert UnknownMarket(marketId);
        if (!m.active) revert MarketInactive(marketId);
        if (!compliance.canTransact(msg.sender)) revert();
        if (amount == 0) revert ZeroAmount();
        accrueInterest(marketId);

        userBorrowIndex[marketId][msg.sender] = borrowIndex[marketId];
        debt[marketId][msg.sender] += amount;
        totalDebt += amount;
        totalSupplied += amount;

        uint256 health = healthFactor(marketId, msg.sender);
        if (health < 1e18) revert Unhealthy(health);
        // the LTV caps new borrows regardless of the health threshold
        uint256 maxDebt = (collateralValue(marketId, msg.sender) * m.ltvBps) / 10_000;
        if (debtOf(marketId, msg.sender) > maxDebt) revert Unhealthy(health);

        // the vault provides the liquidity
        vault.lendToMarkets(amount);
        if (!debtToken.transfer(msg.sender, amount)) revert TransferFailed();
        emit Borrowed(marketId, msg.sender, amount);
    }

    function repay(uint256 marketId, uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        accrueInterest(marketId);
        uint256 owed = debtOf(marketId, msg.sender);
        uint256 pay = amount > owed ? owed : amount;
        if (pay == 0) revert InsufficientDebt(0, amount);
        userBorrowIndex[marketId][msg.sender] = borrowIndex[marketId];
        debt[marketId][msg.sender] = owed - pay;
        totalDebt -= pay;
        if (!debtToken.transferFrom(msg.sender, address(vault), pay)) revert TransferFailed();
        vault.recoverFromMarkets(pay);
        emit Repaid(marketId, msg.sender, pay);
    }

    function withdraw(uint256 marketId, uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        accrueInterest(marketId);
        if (collateral[marketId][msg.sender] < amount) revert InsufficientDebt(collateral[marketId][msg.sender], amount);
        collateral[marketId][msg.sender] -= amount;
        uint256 health = healthFactor(marketId, msg.sender);
        if (health < 1e18) revert Unhealthy(health);
        if (!markets[marketId].collateralToken.transfer(msg.sender, amount)) revert TransferFailed();
        emit Withdrawn(marketId, msg.sender, amount);
    }

    /* ==================== ACCOUNTING ==================== */

    function debtOf(uint256 marketId, address user) public view returns (uint256) {
        uint256 stored = debt[marketId][user];
        if (stored == 0) return 0;
        return stored * borrowIndex[marketId] / userBorrowIndex[marketId][user];
    }

    /// @notice Health factor: (collateral × threshold) / debt, scaled 1e18.
    function healthFactor(uint256 marketId, address user) public view returns (uint256) {
        uint256 owed = debtOf(marketId, user);
        if (owed == 0) return type(uint256).max;
        uint256 collValue = collateralValue(marketId, user);
        return (collValue * markets[marketId].liquidationThresholdBps / 10_000) * 1e18 / owed;
    }

    function collateralValue(uint256 marketId, address user) public view returns (uint256) {
        uint256 amount = collateral[marketId][user];
        if (amount == 0) return 0;
        uint256 price = oracle.price(address(markets[marketId].collateralToken));
        return amount * price / 1e18;
    }

    /* ==================== LIQUIDATION ==================== */

    /// @notice Liquidates an unhealthy position: the liquidator repays the debt and
    ///         receives the seized collateral (with the liquidation bonus) — the
    ///         collateral goes through the auction house for fair pricing.
    function liquidate(uint256 marketId, address user) external {
        accrueInterest(marketId);
        uint256 owed = debtOf(marketId, user);
        if (owed == 0) revert InsufficientDebt(0, 1);
        if (healthFactor(marketId, user) >= 1e18) revert Unhealthy(healthFactor(marketId, user));

        uint256 seized = collateral[marketId][user];
        collateral[marketId][user] = 0;
        debt[marketId][user] = 0;
        totalDebt -= owed;
        userBorrowIndex[marketId][user] = borrowIndex[marketId];

        if (!debtToken.transferFrom(msg.sender, address(vault), owed)) revert TransferFailed();
        vault.recoverFromMarkets(owed);

        // hand the seized collateral to the auction house
        collateralRegistry.startAuction(marketId, user, msg.sender, seized, owed);
        emit Liquidated(marketId, user, msg.sender, owed, seized);
    }
}
