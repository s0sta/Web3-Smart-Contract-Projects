# 22 · Rahala — Cross-Border Payments & Remittance Network

![Solidity](https://img.shields.io/badge/Solidity-0.8.26-363636?logo=solidity&logoColor=white)
![Foundry](https://img.shields.io/badge/Foundry-1.5.1-8b5cf6)
![License](https://img.shields.io/badge/License-MIT-green)
![Tests](https://img.shields.io/badge/tests-37%20green-22c55e)
![Live](https://img.shields.io/badge/Live-s0sta.com%2Frahala-0a2540)

> **Difficulty: ★★★★★★** · The fourth flagship · 🌐 **Live demo: [https://s0sta.com/rahala](https://s0sta.com/rahala)**
> — see [`frontend/README.md`](frontend/README.md)
>
> 📍 **Deployed on Sepolia: [`RahalaAccounts 0x084353D5F680651deDa34073AF768E014E912A6E`](https://sepolia.etherscan.io/address/0x084353D5F680651deDa34073AF768E014E912A6E)** — 12 contracts live (AED-S, USD, compliance, oracle, ledger, treasury, FX, escrow, invoices, netting, disputes, governor) · the first 250,000 AED-S account credit and the 500,000 USD FX float are live — a real-world-usable money-movement
> network: FX conversion, payment escrow, invoice factoring, batch netting and
> dispute arbitration, all on one rail.

## The real-world scenario

Rahala ("journey") is the correspondent-banking workflow on-chain: participants
hold settlement currency, convert into foreign currencies at EMA rates, send
escrowed payments with release conditions, factor trade invoices, net bilateral
obligations in batches, and arbitrate disputes with a 2-of-3 panel:

| Payments function | Contract | Mechanism |
|---|---|---|
| Settlement currency | `RahalaStable` | from-scratch ERC-20 (AED-S), issuer-gated mint/burn |
| Rulebook | `RahalaCompliance` | KYC tiers, transfer + daily caps, sanctions, travel-rule memo, region allowlists |
| FX rates | `RahalaOracle` | EMA-smoothed rates, staleness window, guardian pause |
| Ledger | `RahalaAccounts` | credits/debits with snapshot balances |
| FX desk | `RahalaFX` | conversions at oracle rates with fee + spread and slippage limits |
| Payment rail | `RahalaEscrow` | instant / timelocked / milestone releases, refunds, dispute hooks |
| Trade finance | `RahalaInvoices` | invoice registry + factoring at a disclosed discount |
| Netting | `RahalaSettlement` | batch net settlement of bilateral obligations |
| Fee engine | `RahalaTreasury` | fee collection behind a reserve floor |
| Arbitration | `RahalaDisputes` | 2-of-3 arbiters, evidence hashes, binding awards |
| Governance | `RahalaGovernor` | balance-weighted parameter voting with quorum + timelock |

## Security model

- **Compliance at the rail** — every payment and conversion passes KYC, sanctions,
  region and cap checks with a travel-rule memo
- **Conditional release** — escrowed funds cannot move before their release
  condition; disputes route to binding arbitration
- **EMA pricing** — a single bad FX print cannot skew a conversion
- **Net settlement** — the engine verifies net amounts against recorded gross
  obligations before moving funds
- **2-of-3 panels** for disputes; timelocked, allowlisted governance

## Quick start

```bash
forge test    # 37 tests
forge build
anvil
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

## Production hardening

- Licensed money-transmitter rails, decentralized FX sources, independent audit.

## License

MIT — see [LICENSE](../LICENSE).
