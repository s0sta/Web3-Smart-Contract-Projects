// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";
import {AccessControl} from "./AccessControl.sol";
import {SahmCompliance} from "./SahmCompliance.sol";
import {SahmRisk} from "./SahmRisk.sol";
import {SahmTreasury} from "./SahmTreasury.sol";

/// @title SahmAMM
/// @notice The automated market-maker desk: x·y=k pools per market with LP shares,
///         proportional liquidity provisioning, slippage-limited swaps and a
///         protocol fee routed to the treasury.
contract SahmAMM is AccessControl {
    /// @notice The operator lists pools.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR");

    /// @notice One pool.
    struct Pool {
        IERC20 token;
        uint256 reserveToken;
        uint256 reserveQuote;
        uint256 lpShares; // total supply
        bool active;
    }

    Pool[] public pools;
    mapping(uint256 poolId => mapping(address lp => uint256)) public lpBalance;

    uint256 public feeBps; // total swap fee
    uint256 public protocolFeeShareBps; // of the fee, routed to the treasury

    SahmCompliance public immutable compliance;
    SahmRisk public immutable risk;
    SahmTreasury public immutable treasury;
    IERC20 public immutable quoteToken;

    event PoolListed(uint256 indexed poolId, address token);
    event LiquidityAdded(uint256 indexed poolId, address indexed lp, uint256 tokenAmount, uint256 quoteAmount, uint256 shares);
    event LiquidityRemoved(uint256 indexed poolId, address indexed lp, uint256 tokenAmount, uint256 quoteAmount, uint256 shares);
    event Swapped(uint256 indexed poolId, address indexed trader, bool tokenIn, uint256 amountIn, uint256 amountOut);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownPool(uint256 poolId);
    error PoolInactive(uint256 poolId);
    error InsufficientLp(uint256 balance, uint256 shares);
    error InsufficientOutput(uint256 output, uint256 minOutput);
    error TransferFailed();

    constructor(
        SahmCompliance compliance_,
        SahmRisk risk_,
        SahmTreasury treasury_,
        IERC20 quoteToken_
    ) {
        if (address(compliance_) == address(0) || address(risk_) == address(0) || address(treasury_) == address(0) || address(quoteToken_) == address(0)) {
            revert ZeroAddress();
        }
        compliance = compliance_;
        risk = risk_;
        treasury = treasury_;
        quoteToken = quoteToken_;
        feeBps = 30; // 0.3%
        protocolFeeShareBps = 2000; // 20% of the fee
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
    }

    /* ==================== POOLS ==================== */

    function listPool(IERC20 token) external onlyRole(OPERATOR_ROLE) returns (uint256 poolId) {
        if (address(token) == address(0)) revert ZeroAddress();
        poolId = pools.length;
        pools.push();
        pools[poolId].token = token;
        pools[poolId].active = true;
        emit PoolListed(poolId, address(token));
    }

    /* ==================== LIQUIDITY ==================== */

    function addLiquidity(uint256 poolId, uint256 tokenAmount, uint256 quoteAmount) external returns (uint256 shares) {
        Pool storage p = pools[poolId];
        if (p.token == IERC20(address(0))) revert UnknownPool(poolId);
        if (!p.active) revert PoolInactive(poolId);
        if (tokenAmount == 0 || quoteAmount == 0) revert ZeroAmount();

        if (p.lpShares == 0) {
            shares = quoteAmount; // seed shares = quote contribution
        } else {
            uint256 shareToken = (tokenAmount * p.lpShares) / p.reserveToken;
            uint256 shareQuote = (quoteAmount * p.lpShares) / p.reserveQuote;
            shares = shareToken < shareQuote ? shareToken : shareQuote;
        }
        if (shares == 0) revert ZeroAmount();

        p.reserveToken += tokenAmount;
        p.reserveQuote += quoteAmount;
        p.lpShares += shares;
        lpBalance[poolId][msg.sender] += shares;

        if (!p.token.transferFrom(msg.sender, address(this), tokenAmount)) revert TransferFailed();
        if (!quoteToken.transferFrom(msg.sender, address(this), quoteAmount)) revert TransferFailed();
        emit LiquidityAdded(poolId, msg.sender, tokenAmount, quoteAmount, shares);
    }

    function removeLiquidity(uint256 poolId, uint256 shares) external {
        Pool storage p = pools[poolId];
        if (shares == 0) revert ZeroAmount();
        if (lpBalance[poolId][msg.sender] < shares) revert InsufficientLp(lpBalance[poolId][msg.sender], shares);

        uint256 tokenOut = (shares * p.reserveToken) / p.lpShares;
        uint256 quoteOut = (shares * p.reserveQuote) / p.lpShares;
        lpBalance[poolId][msg.sender] -= shares;
        p.lpShares -= shares;
        p.reserveToken -= tokenOut;
        p.reserveQuote -= quoteOut;

        if (!p.token.transfer(msg.sender, tokenOut)) revert TransferFailed();
        if (!quoteToken.transfer(msg.sender, quoteOut)) revert TransferFailed();
        emit LiquidityRemoved(poolId, msg.sender, tokenOut, quoteOut, shares);
    }

    /* ==================== SWAPS ==================== */

    /// @notice Buys the pool's token with the quote (slippage-limited).
    function swapQuoteForToken(uint256 poolId, uint256 quoteIn, uint256 minTokenOut) external returns (uint256 tokenOut) {
        Pool storage p = pools[poolId];
        if (p.token == IERC20(address(0))) revert UnknownPool(poolId);
        if (!p.active) revert PoolInactive(poolId);
        if (!compliance.canTrade(msg.sender)) revert();
        if (quoteIn == 0) revert ZeroAmount();

        uint256 fee = (quoteIn * feeBps) / 10_000;
        uint256 netIn = quoteIn - fee;
        uint256 k = p.reserveToken * p.reserveQuote;
        tokenOut = p.reserveToken - (k / (p.reserveQuote + netIn));

        if (tokenOut < minTokenOut) revert InsufficientOutput(tokenOut, minTokenOut);

        p.reserveQuote += netIn;
        p.reserveToken -= tokenOut;
        uint256 protocolFee = (fee * protocolFeeShareBps) / 10_000;

        if (!quoteToken.transferFrom(msg.sender, address(this), quoteIn)) revert TransferFailed();
        if (!p.token.transfer(msg.sender, tokenOut)) revert TransferFailed();
        if (protocolFee > 0) {
            if (!quoteToken.approve(address(treasury), protocolFee)) revert TransferFailed();
            treasury.receiveFees(protocolFee);
        }

        compliance.recordVolume(msg.sender, quoteIn);
        risk.recordVolume(address(p.token), quoteIn);
        emit Swapped(poolId, msg.sender, false, quoteIn, tokenOut);
    }

    /// @notice Sells the pool's token for the quote.
    function swapTokenForQuote(uint256 poolId, uint256 tokenIn, uint256 minQuoteOut) external returns (uint256 quoteOut) {
        Pool storage p = pools[poolId];
        if (p.token == IERC20(address(0))) revert UnknownPool(poolId);
        if (!p.active) revert PoolInactive(poolId);
        if (!compliance.canTrade(msg.sender)) revert();
        if (tokenIn == 0) revert ZeroAmount();

        uint256 k = p.reserveToken * p.reserveQuote;
        quoteOut = p.reserveQuote - (k / (p.reserveToken + tokenIn));
        uint256 fee = (quoteOut * feeBps) / 10_000;
        uint256 netOut = quoteOut - fee;

        if (netOut < minQuoteOut) revert InsufficientOutput(netOut, minQuoteOut);

        p.reserveToken += tokenIn;
        p.reserveQuote -= quoteOut;
        uint256 protocolFee = (fee * protocolFeeShareBps) / 10_000;

        if (!p.token.transferFrom(msg.sender, address(this), tokenIn)) revert TransferFailed();
        if (!quoteToken.transfer(msg.sender, netOut)) revert TransferFailed();
        if (protocolFee > 0) {
            if (!quoteToken.approve(address(treasury), protocolFee)) revert TransferFailed();
            treasury.receiveFees(protocolFee);
        }

        compliance.recordVolume(msg.sender, quoteOut);
        risk.recordVolume(address(p.token), quoteOut);
        emit Swapped(poolId, msg.sender, true, tokenIn, quoteOut);
    }

    function poolCount() external view returns (uint256) {
        return pools.length;
    }

    function lpSharesI(uint256 poolId) external view returns (uint256) {
        return pools[poolId].lpShares;
    }

    function quotePrice(uint256 poolId) external view returns (uint256) {
        Pool storage p = pools[poolId];
        if (p.reserveToken == 0) return 0;
        return (p.reserveQuote * 1e18) / p.reserveToken;
    }

    /* ==================== ADMIN ==================== */

    function setFees(uint256 feeBps_, uint256 protocolShareBps) external onlyRole(OPERATOR_ROLE) {
        if (feeBps_ > 1000 || protocolShareBps > 10_000) revert ZeroAmount();
        feeBps = feeBps_;
        protocolFeeShareBps = protocolShareBps;
    }
}
