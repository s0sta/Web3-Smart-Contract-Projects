# 20 · Tamweel — Decentralized Credit Protocol (a complete digital bank)

![Solidity](https://img.shields.io/badge/Solidity-0.8.26-363636?logo=solidity&logoColor=white)
![Foundry](https://img.shields.io/badge/Foundry-1.5.1-8b5cf6)
![License](https://img.shields.io/badge/License-MIT-green)
![Tests](https://img.shields.io/badge/tests-47%20green-22c55e)
![Live](https://img.shields.io/badge/Live-s0sta.com%2Ftamweel-6e1423)

> **Difficulty: ★★★★★★** · The second flagship · 🌐 **Live demo: [https://s0sta.com/tamweel](https://s0sta.com/tamweel)**
> — see [`frontend/README.md`](frontend/README.md)
>
> 📍 **Deployed on Sepolia: [`TamweelVault 0x8F05B5167decaD8266f01C11f333AAAA475C19bD`](https://sepolia.etherscan.io/address/0x8F05B5167decaD8266f01C11f333AAAA475C19bD)** — 10 contracts live (credit bureau → oracle → vault → rates → markets → loans → auctions → insurance → governor) · the first 250,000 AED-S deposit is live — a real-world-usable digital bank:
> depositors earn the supply rate; borrowers post collateral, take loans or draw credit
> lines; liquidators close unhealthy positions through Dutch auctions; bad debt is
> backstopped by an insurance fund; and depositors govern the parameters.

## The real-world scenario

Tamweel ("financing") is the full credit cycle on-chain: retail depositors fund the bank,
the bank prices money with a utilization curve, businesses and individuals borrow against
collateral or credit scores, repay on schedules (with late fees donated to charity), and
the system self-heals through liquidations and an insurance backstop:

| Banking function | Contract | Mechanism |
|---|---|---|
| Credit bureau | `TamweelCompliance` | KYC tiers, credit scores (0–1000), per-score borrowing bands, sanctions |
| Price feeds | `TamweelOracle` | EMA-smoothed prices (manipulation-resistant), staleness + pause |
| Deposits | `TamweelVault` | from-scratch share accounting, snapshots, a liquidity buffer withdrawals can't breach |
| Pricing | `TamweelRateModel` | two-slope utilization curve with a reserve factor |
| Collateralized credit | `TamweelMarkets` | supply / borrow / repay / liquidate with health factors and per-second interest via global indices |
| Installment loans | `TamweelLoans` | credit-gated, committee-approved, fixed disclosed interest, late fees → charity, early-settlement rebates, default + recovery |
| Liquidation auctions | `TamweelCollateral` | Dutch-auction pricing of seized collateral, proceeds to the liquidator |
| Bad-debt backstop | `TamweelInsuranceFund` | funded by the reserve factor, 2-of-3 committee payouts into the vault |
| Governance | `TamweelGovernor` | vault-share-weighted parameter voting with quorum + timelock |

## Contracts

| Contract | Path | Responsibility |
|---|---|---|
| `TamweelCompliance` | [`src/TamweelCompliance.sol`](src/TamweelCompliance.sol) | KYC, credit scores, borrowing bands |
| `TamweelOracle` | [`src/TamweelOracle.sol`](src/TamweelOracle.sol) | EMA price feed |
| `TamweelVault` | [`src/TamweelVault.sol`](src/TamweelVault.sol) | deposits, shares, liquidity buffer |
| `TamweelRateModel` | [`src/TamweelRateModel.sol`](src/TamweelRateModel.sol) | utilization curve |
| `TamweelMarkets` | [`src/TamweelMarkets.sol`](src/TamweelMarkets.sol) | collateralized lending + liquidations |
| `TamweelLoans` | [`src/TamweelLoans.sol`](src/TamweelLoans.sol) | installment loan book |
| `TamweelCollateral` | [`src/TamweelCollateral.sol`](src/TamweelCollateral.sol) | Dutch-auction liquidations |
| `TamweelInsuranceFund` | [`src/TamweelInsuranceFund.sol`](src/TamweelInsuranceFund.sol) | bad-debt backstop |
| `TamweelGovernor` | [`src/TamweelGovernor.sol`](src/TamweelGovernor.sol) | parameter governance |

## Security model

- **LTV + health double gate** — new borrows must respect the LTV cap AND keep the
  health factor ≥ 1; withdrawals that would unhealth a position revert
- **Manipulation-resistant pricing** — EMA-smoothed oracle with staleness checks
- **Solvent by construction** — the vault only lends its liquid buffer-free assets;
  repayments and liquidation proceeds return liquidity before anything else
- **Charity-routed late fees** — the bank structurally cannot profit from delinquency
- **2-of-3 committees** for loans and insurance payouts; timelocked, allowlisted governance

## Quick start

```bash
forge test    # 47 tests
forge build
anvil
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

## Production hardening

- Chainlink-style decentralized price sources, off-chain credit attestations,
  independent audit before real funds.

## License

MIT — see [LICENSE](../LICENSE).
