# 12 · Estate Tokenization — Fractional Real Estate with Rental Distributions

![Solidity](https://img.shields.io/badge/Solidity-0.8.26-363636?logo=solidity&logoColor=white)
![Foundry](https://img.shields.io/badge/Foundry-1.5.1-8b5cf6)
![License](https://img.shields.io/badge/License-MIT-green)
![Tests](https://img.shields.io/badge/tests-20%20green-22c55e)
![Live](https://img.shields.io/badge/Live-s0sta.com%2Festate-e2714b)

> **Difficulty: ★★★★★** · Flagship series #2 · 🌐 **Live demo: [https://s0sta.com/estate](https://s0sta.com/estate)**
> — see [`frontend/README.md`](frontend/README.md)
>
> 📍 **Deployed on Sepolia: [`RERAPropertyRegistry 0x12dd8571779A707E931471c38D631D8542046180`](https://sepolia.etherscan.io/address/0x12dd8571779A707E931471c38D631D8542046180)** · distributor `0xc712…6D9a` · AED-S `0x05cD…42Ee` · "Marina Gate Tower" (1,000 shares) · Q3 rent paid and distributed — 3,600 AED-S claimable — the DLD/RERA real-estate tokenization pattern:
> properties registered with appraisals, split into fractional shares, KYC-gated ownership,
> and rental income distributed pro-rata through snapshot-based epochs.

## The real-world scenario

Dubai's DLD and RERA have moved toward tokenizing real-estate assets: a building is appraised,
fractionalized into shares, and investors receive rental yields in proportion to their holdings.
This protocol puts that entire workflow on-chain:

| Real-estate concept | On-chain implementation |
|---|---|
| Property registration & appraisal | `registerProperty(name, shares, valuationUsd)` + `appraise()` audit trail |
| Fractional shares | fixed-supply share ledger per property (from-scratch ERC-20-style balances) |
| Investor KYC | per-property whitelist, enforced on issuance AND transfers (both sides) |
| Regulator oversight | compliance role: KYC, freezes (no transfers/issuance while frozen) |
| Rental income | rent payments in an AED-pegged stable |
| Maintenance reserve | 10% of every rent withheld before distribution |
| Yield distribution | **epochs**: each `distribute()` snapshots the pool at a block; holders claim
  `sharesAtSnapshot × perShare` — shares sold after an epoch cannot take that epoch's income |
| Property management | manager role issues shares, spends the maintenance fund, files appraisals |

**Portability**: the same pattern maps to any jurisdiction's fractional-ownership regime —
only the KYC source and the reserve ratio change.

## Contracts

| Contract | Path | Responsibility |
|---|---|---|
| `RERAPropertyRegistry` | [`src/RERAPropertyRegistry.sol`](src/RERAPropertyRegistry.sol) | property ledger, shares, KYC, freeze, snapshots |
| `RentalDistributor` | [`src/RentalDistributor.sol`](src/RentalDistributor.sol) | rent, reserve, distribution epochs, claims, maintenance |
| `AccessControl` / `Checkpoints` / `MockStable` | [`src/`](src) | shared from-scratch primitives |

## Security model

- **Snapshot-based entitlements** — claims use the registry's historical balances at each
  epoch's snapshot block; a sale can never redirect past income
- **KYC on both sides** of every transfer; compliance freezes stop the whole property
- **Reserve discipline** — the maintenance fund can only be spent by the manager role
- **Exact-supply issuance** — issuance can never exceed the registered share count
- **CEI + transferFrom-first** — no reentrancy surface

## Quick start

```bash
forge test    # 20 tests
forge build
anvil
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

## Production hardening

- Replace the mock stable with a regulated AED-pegged stablecoin; add an oracle for
  valuation updates; integrate a licensed KYC provider signature scheme for whitelisting;
  independent audit.

## License

MIT — see [LICENSE](../LICENSE).
