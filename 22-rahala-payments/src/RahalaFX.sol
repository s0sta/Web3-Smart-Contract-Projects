// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "./AccessControl.sol";
import {RahalaStable} from "./RahalaStable.sol";
import {RahalaOracle} from "./RahalaOracle.sol";
import {RahalaCompliance} from "./RahalaCompliance.sol";
import {RahalaTreasury} from "./RahalaTreasury.sol";
import {IERC20} from "./interfaces/IERC20.sol";

/// @title RahalaFX
/// @notice The foreign-exchange desk: participants convert between supported
///         currencies at oracle rates plus a spread, with slippage protection.
///         The desk holds each currency's liquidity (as stable-denominated
///         reserves) and converts atomically.
contract RahalaFX is AccessControl {
    /// @notice The operator lists currencies.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR");

    /// @notice One supported currency (the ERC-20 used off-chain; on-chain the
    ///         desk works in stable-denominated value).
    struct Currency {
        address token;
        string code;
        uint64 region;
        bool active;
    }

    mapping(address token => Currency) public currencies;

    /// @notice The desk's stable-denominated liquidity per currency.
    mapping(address token => uint256) public liquidity;

    /// @notice Conversion fee (bps) and spread (bps).
    uint256 public feeBps;
    uint256 public spreadBps;

    RahalaStable public immutable settlement;
    RahalaOracle public immutable oracle;
    RahalaCompliance public immutable compliance;
    RahalaTreasury public immutable treasury;

    event CurrencyListed(address indexed token, string code, uint64 region);
    event Converted(address indexed from, address indexed to, address currency, uint256 amountIn, uint256 amountOut);
    event LiquidityAdded(address indexed currency, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownCurrency(address currency);
    error CurrencyInactive(address currency);
    error InsufficientLiquidity(uint256 available, uint256 needed);
    error Slippage(uint256 output, uint256 minOutput);
    error TransferFailed();

    constructor(
        RahalaStable settlement_,
        RahalaOracle oracle_,
        RahalaCompliance compliance_,
        RahalaTreasury treasury_
    ) {
        if (address(settlement_) == address(0) || address(oracle_) == address(0) || address(compliance_) == address(0) || address(treasury_) == address(0)) {
            revert ZeroAddress();
        }
        settlement = settlement_;
        oracle = oracle_;
        compliance = compliance_;
        treasury = treasury_;
        feeBps = 50; // 0.5%
        spreadBps = 20; // 0.2%
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    /* ==================== CURRENCIES & LIQUIDITY ==================== */

    function listCurrency(address token, string calldata code, uint64 region) external onlyRole(OPERATOR_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        currencies[token] = Currency({ token: token, code: code, region: region, active: true });
        emit CurrencyListed(token, code, region);
    }

    function setCurrencyActive(address token, bool active) external onlyRole(OPERATOR_ROLE) {
        if (currencies[token].token == address(0)) revert UnknownCurrency(token);
        currencies[token].active = active;
    }

    /// @notice The operator funds the desk's foreign-currency float.
    function addLiquidity(address currency, uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (!IERC20(currency).transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        liquidity[currency] += amount;
        emit LiquidityAdded(currency, amount);
    }

    /* ==================== CONVERSION ==================== */

    /// @notice Converts the settlement stable into a foreign currency (credited
    ///         as stable-denominated value in that currency's liquidity).
    function convertTo(address currency, uint256 amountIn, uint256 minAmountOut) external returns (uint256 amountOut) {
        Currency storage c = currencies[currency];
        if (c.token == address(0)) revert UnknownCurrency(currency);
        if (!c.active) revert CurrencyInactive(currency);
        if (amountIn == 0) revert ZeroAmount();
        compliance.validateTransfer(msg.sender, msg.sender, c.region, amountIn, bytes32(uint256(1)));

        uint256 rate = oracle.rate(currency);
        uint256 gross = (amountIn * 1e18) / rate;
        uint256 fee = (gross * feeBps) / 10_000;
        uint256 spread = (gross * spreadBps) / 10_000;
        amountOut = gross - fee - spread;
        if (amountOut < minAmountOut) revert Slippage(amountOut, minAmountOut);
        if (liquidity[currency] < amountOut) revert InsufficientLiquidity(liquidity[currency], amountOut);

        if (!settlement.transferFrom(msg.sender, address(this), amountIn)) revert TransferFailed();
        liquidity[currency] -= amountOut;
        if (!IERC20(currency).transfer(msg.sender, amountOut)) revert TransferFailed();
        if (fee > 0) {
            if (!settlement.approve(address(treasury), fee)) revert TransferFailed();
            treasury.receiveFees(fee);
        }
        emit Converted(msg.sender, msg.sender, currency, amountIn, amountOut);
    }

    /// @notice Converts a foreign currency back into the settlement stable.
    function convertFrom(address currency, uint256 amountIn, uint256 minAmountOut) external returns (uint256 amountOut) {
        Currency storage c = currencies[currency];
        if (c.token == address(0)) revert UnknownCurrency(currency);
        if (!c.active) revert CurrencyInactive(currency);
        if (amountIn == 0) revert ZeroAmount();

        uint256 rate = oracle.rate(currency);
        uint256 gross = (amountIn * rate) / 1e18;
        uint256 fee = (gross * feeBps) / 10_000;
        amountOut = gross - fee;
        if (amountOut < minAmountOut) revert Slippage(amountOut, minAmountOut);
        if (settlement.balanceOf(address(this)) < amountOut) revert InsufficientLiquidity(settlement.balanceOf(address(this)), amountOut);

        if (!IERC20(currency).transferFrom(msg.sender, address(this), amountIn)) revert TransferFailed();
        liquidity[currency] += amountIn;
        if (!settlement.transfer(msg.sender, amountOut)) revert TransferFailed();
        if (fee > 0) {
            if (!settlement.approve(address(treasury), fee)) revert TransferFailed();
            treasury.receiveFees(fee);
        }
        emit Converted(msg.sender, msg.sender, currency, amountIn, amountOut);
    }

    /* ==================== ADMIN ==================== */

    function setFees(uint256 feeBps_, uint256 spreadBps_) external onlyRole(OPERATOR_ROLE) {
        if (feeBps_ > 1000 || spreadBps_ > 1000) revert ZeroAmount();
        feeBps = feeBps_;
        spreadBps = spreadBps_;
    }
}
