# 14 · VARA Treasury — Regulated VASP Treasury

![Solidity](https://img.shields.io/badge/Solidity-0.8.26-363636?logo=solidity&logoColor=white)
![Foundry](https://img.shields.io/badge/Foundry-1.5.1-8b5cf6)
![License](https://img.shields.io/badge/License-MIT-green)
![Tests](https://img.shields.io/badge/tests-29%20green-22c55e)
![Live](https://img.shields.io/badge/Live-s0sta.com%2Fvara-f2a53a)

> **Difficulty: ★★★★★** · Flagship series #4 · 🌐 **Live demo: [https://s0sta.com/vara](https://s0sta.com/vara)**
> — see [`frontend/README.md`](frontend/README.md)
>
> 📍 **Deployed on Sepolia: [`VASPTreasury 0xfB14587cd6bd501Ac4e53b65904D08d597950818`](https://sepolia.etherscan.io/address/0xfB14587cd6bd501Ac4e53b65904D08d597950818)** · compliance `0x4004…15BF` · AED-S `0x2dCA…Bd7` · "Desert Exchange FZE" — 30,000 house equity, first 25,000 client deposit live — the treasury of a licensed VASP under a
> **VARA-style regime** (Dubai's Virtual Assets Regulatory Authority): segregated client
> assets, KYC-tiered risk limits, capital-reserve enforcement, and regulator powers.

## The real-world scenario

A VARA-licensed Virtual Asset Service Provider must segregate client assets from house
assets, screen counterparties, cap withdrawals by customer risk tier, hold capital against
liabilities, and give the regulator freeze/drain powers. This protocol encodes that rulebook:

| Regulatory requirement | On-chain implementation |
|---|---|
| Client/house asset segregation | separate ledgers per asset; client funds move only on client instructions |
| KYC tiers | `ComplianceModule`: None / Standard / Enhanced with per-tier limits |
| Per-transaction & daily withdrawal limits | rolling 24h windows per client, tier ceilings |
| Capital reserve | house equity ≥ `reserveBps` × client liabilities **per asset**, checked on every outflow |
| Counterparty whitelisting | withdrawals to non-self destinations require an approved counterparty |
| Sanction screening | sanctioned/frozen accounts are blocked from every flow |
| Regulator powers | compliance can freeze accounts and **force-transfer** to the licensed recovery address |
| Emergency powers | guardian pause + full **emergency drain** to the recovery address |
| Audit trail | every flow is an event; client totals are **checkpointed per block** |

## Contracts

| Contract | Path | Responsibility |
|---|---|---|
| `VASPTreasury` | [`src/VASPTreasury.sol`](src/VASPTreasury.sol) | multi-asset custody, limits, reserve, freeze/forced-transfer, drain |
| `ComplianceModule` | [`src/ComplianceModule.sol`](src/ComplianceModule.sol) | KYC tiers, sanction list, counterparties, risk limits |
| `AccessControl` / `Checkpoints` / `MockStable` | [`src/`](src) | shared from-scratch primitives |

## Security model

- **Segregation invariant** — house withdrawals can never touch client ledgers and vice
  versa; the drain is the only path that collapses them, and only while paused by the guardian
- **Reserve-first** — every outflow (client or house) re-checks the per-asset capital ratio
- **Compliance-gated enforcement** — freeze → forced-transfer → recovery, with events at
  every step; `CEI` ordering throughout; no reentrancy surface
- **Rolling windows** — daily limits reset by block timestamp, so they cannot be gamed
  across boundaries within a single transaction

## Quick start

```bash
forge test    # 29 tests
forge build
anvil
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

## Production hardening

- Feed the sanction list and KYC tiers from an oracle/signed attestations; multi-sig the
  guardian role; independent audit before any real client funds.

## License

MIT — see [LICENSE](../LICENSE).
