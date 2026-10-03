# 19 · Mawarid — End-to-End Real-World Asset (RWA) Investment Platform

![Solidity](https://img.shields.io/badge/Solidity-0.8.26-363636?logo=solidity&logoColor=white)
![Foundry](https://img.shields.io/badge/Foundry-1.5.1-8b5cf6)
![License](https://img.shields.io/badge/License-MIT-green)
![Tests](https://img.shields.io/badge/tests-53%20green-22c55e)
![Live](https://img.shields.io/badge/Live-s0sta.com%2Fmawarid-0d4f5a)

> **Difficulty: ★★★★★★** · The flagship · 🌐 **Live demo: [https://s0sta.com/mawarid](https://s0sta.com/mawarid)**
> — see [`frontend/README.md`](frontend/README.md)
>
> 📍 **Deployed on Sepolia: [`MawaridAssetRegistry 0x7A688e184ab92b97a0062fA0A752E07974627C50`](https://sepolia.etherscan.io/address/0x7A688e184ab92b97a0062fA0A752E07974627C50)** — 9 contracts live ("Marina Gate Tower — Floor 21", 1,000 shares) · phase #0 open · first 400 shares subscribed — a production-shaped, real-world-usable platform
> for tokenized real estate: **registration → KYC → primary issuance → OTC secondary market →
> rental distributions → governance → treasury → insurance**, all in one system.

## The real-world scenario

Mawarid ("resources") is the full institutional workflow for tokenizing real estate the way
Dubai's DLD/RERA regime envisions it — a property is appraised and fractionalized, investors
subscribe in a primary phase, shares trade on a compliant secondary market, rents are
distributed by epoch snapshots, holders govern their asset, the platform treasury holds
reserves, and an insurance fund covers tenant defaults:

| Stage | Contract | Mechanism |
|---|---|---|
| Registration & appraisal | `MawaridAssetRegistry` | documentation hash, appraisal history, lifecycle (Draft → Live → Frozen → Liquidated) |
| KYC & limits | `MawaridCompliance` | KYC tiers (Standard/Accredited), sanctions, per-asset exposure caps & minimums |
| Fractional shares | `MawaridShares` | from-scratch ERC-20, compliance-gated on every transfer, per-block balance snapshots |
| Primary issuance | `MawaridPrimaryMarket` | phased subscriptions: caps, windows, escrowed payments, pro-rata allocations with refunds, cancellation refunds |
| Secondary trading | `MawaridSecondaryMarket` | OTC limit sell orders with escrowed shares, fills at the ask, platform fees to the treasury |
| Rental income | `MawaridRentalDistributor` | maintenance reserve withheld; epoch-based pro-rata distributions by snapshot balances |
| Asset governance | `MawaridAssetGovernor` | five proposal types (appraisal, reserve, manager, payout, rules), token-weighted voting, per-type quorums, timelock, bubbled reverts |
| Platform treasury | `MawaridTreasury` | fee collection, vendor payments with a reserve floor, guardian drain |
| Risk | `MawaridInsuranceFund` | per-asset premium pools; rental-shortfall claims need 2-of-3 assessor approvals |

## Contracts

| Contract | Path | Lines | Responsibility |
|---|---|---|---|
| `MawaridAssetRegistry` | [`src/MawaridAssetRegistry.sol`](src/MawaridAssetRegistry.sol) | ~170 | property ledger, appraisals, lifecycle |
| `MawaridCompliance` | [`src/MawaridCompliance.sol`](src/MawaridCompliance.sol) | ~140 | KYC, sanctions, exposure limits |
| `MawaridShares` | [`src/MawaridShares.sol`](src/MawaridShares.sol) | ~200 | gated ERC-20 + snapshots |
| `MawaridPrimaryMarket` | [`src/MawaridPrimaryMarket.sol`](src/MawaridPrimaryMarket.sol) | ~210 | subscription phases |
| `MawaridSecondaryMarket` | [`src/MawaridSecondaryMarket.sol`](src/MawaridSecondaryMarket.sol) | ~210 | OTC orders + fees |
| `MawaridRentalDistributor` | [`src/MawaridRentalDistributor.sol`](src/MawaridRentalDistributor.sol) | ~190 | income epochs + reserve |
| `MawaridAssetGovernor` | [`src/MawaridAssetGovernor.sol`](src/MawaridAssetGovernor.sol) | ~290 | token-weighted governance |
| `MawaridTreasury` | [`src/MawaridTreasury.sol`](src/MawaridTreasury.sol) | ~150 | fees, vendors, reserve |
| `MawaridInsuranceFund` | [`src/MawaridInsuranceFund.sol`](src/MawaridInsuranceFund.sol) | ~180 | premium pools, claims |

**1,600+ lines of contracts · 53 tests · full dApp** — see [`frontend/README.md`](frontend/README.md).

## Security model

- **Compliance at the token layer** — no transfer, mint or fill can bypass KYC, sanctions
  or exposure caps (the market's own escrow must be KYC'd)
- **Snapshot entitlements everywhere** — distributions and governance read historical
  balances; a sale can never redirect past income or votes
- **Reserve floors** — the treasury cannot pay below its reserve; the distributor withholds
  maintenance before distributions
- **2-of-3 claim committee** for the insurance fund; timelocked governance with bubbled
  revert reasons; CEI ordering throughout

## Quick start

```bash
forge test    # 53 tests
forge build
anvil
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

## Production hardening

- Title-deed and valuation oracles, licensed KYC attestations, dispute arbitration,
  independent audit before real funds.

## License

MIT — see [LICENSE](../LICENSE).
