# 21 · Sahm — Decentralized Exchange & Derivatives Platform

![Solidity](https://img.shields.io/badge/Solidity-0.8.26-363636?logo=solidity&logoColor=white)
![Foundry](https://img.shields.io/badge/Foundry-1.5.1-8b5cf6)
![License](https://img.shields.io/badge/License-MIT-green)
![Tests](https://img.shields.io/badge/tests-45%20green-22c55e)
![Live](https://img.shields.io/badge/Live-s0sta.com%2Fsahm-5b8def)

> **Difficulty: ★★★★★★** · The third flagship · 🌐 **Live demo: [https://s0sta.com/sahm](https://s0sta.com/sahm)**
> — see [`frontend/README.md`](frontend/README.md)
>
> 📍 **Deployed on Sepolia: [`SahmCollateral 0xb438AbC481c3888C83fcDcE7143ED087F724B77b`](https://sepolia.etherscan.io/address/0xb438AbC481c3888C83fcDcE7143ED087F724B77b)** — 11 contracts live · ETH market listed (2,000 AED-S) · first margin account + AMM pool seeded — a real-world-usable exchange:
> limit order books, AMM pools, leveraged margin with funding, liquidation
> backstops, risk circuit breakers and LP governance.

## The real-world scenario

Sahm ("share") is the full trading lifecycle on-chain: traders pass KYC and daily
volume limits, trade spot on a price–time order book or against AMM pools, take
leveraged positions against EMA-priced feeds, get liquidated when below maintenance
margin, and LP holders govern the venue's fees and risk parameters:

| Exchange function | Contract | Mechanism |
|---|---|---|
| Trading rules | `SahmCompliance` | KYC tiers, per-tier daily volume caps, sanctions, trading halt |
| Price feeds | `SahmOracle` | EMA-smoothed prices, staleness window, guardian pause |
| Margin custody | `SahmCollateral` | deposits/withdrawals, margin locks, snapshot balances, payouts |
| Fee engine | `SahmTreasury` | fee collection, vendor payments behind a reserve floor, guardian drain |
| Risk engine | `SahmRisk` | position caps, rolling volume caps, circuit breakers on price moves |
| Spot trading | `SahmOrderBook` | limit bids/asks, price–time matching, escrowed funds, maker/taker fees |
| Automated liquidity | `SahmAMM` | x·y=k pools, LP shares, slippage-limited swaps, protocol fees |
| Derivatives | `SahmMargin` | leveraged longs/shorts, funding, PnL settlement, liquidation |
| Backstop | `SahmInsuranceFund` | liquidation-loss coverage with 2-of-3 committee payouts |
| Governance | `SahmGovernor` | LP-share-weighted parameter voting with quorum + timelock |

## Security model

- **EMA pricing** — a single manipulated price print cannot crash collateral
- **Circuit breakers** — a move beyond the band halts the market and persists
- **Escrowed order books** — resting orders lock real funds; cancellation refunds
- **Maintenance-margin liquidations** with a liquidator bonus carved from margin
- **2-of-3 committee** insurance payouts; timelocked, allowlisted governance

## Quick start

```bash
forge test    # 45 tests
forge build
anvil
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

## Production hardening

- Decentralized price sources, on-chain settlement rails, independent audit.

## License

MIT — see [LICENSE](../LICENSE).
