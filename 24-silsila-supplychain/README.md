# 24 · Silsila — Supply Chain & Logistics Platform

![Solidity](https://img.shields.io/badge/Solidity-0.8.26-363636?logo=solidity&logoColor=white)
![Foundry](https://img.shields.io/badge/Foundry-1.5.1-8b5cf6)
![License](https://img.shields.io/badge/License-MIT-green)
![Tests](https://img.shields.io/badge/tests-43%20green-22c55e)
![Live](https://img.shields.io/badge/Live-s0sta.com%2Fsilsila-ff6d1f)

> **Difficulty: ★★★★★★** · The sixth flagship · 🌐 **Live demo: [https://s0sta.com/silsila](https://s0sta.com/silsila)**
> — see [`frontend/README.md`](frontend/README.md)
>
> 📍 **Deployed on Sepolia: [`SilsilaRegistry 0x62D09186787FE0af9F34724022DB26795F10812c`](https://sepolia.etherscan.io/address/0x62D09186787FE0af9F34724022DB26795F10812c)** — 12 contracts live (registry, compliance, orders, shipments, quality, payments, cargo, reputation, treasury, oracle, governor) · the owner's business entity and 500,000 AED-S insurer capital are live — a real-world-usable trade rail:
> purchase orders, tracked shipments with proof-of-delivery, quality inspections,
> milestone payments, cargo insurance and performance reputation.

## The real-world scenario

Silsila ("chain") digitizes the physical trade cycle: a buyer issues a purchase
order, the supplier accepts, a carrier moves the shipment through milestones with
location hashes, an auditor grades the delivered goods, payments release only as
milestones are reached (with late penalties), cargo is insured, and every entity
earns a performance reputation:

| Trade function | Contract | Mechanism |
|---|---|---|
| Business registry | `SilsilaRegistry` | roles (buyer/supplier/carrier/auditor/financier), KYC tiers, sanctions |
| Trade compliance | `SilsilaCompliance` | export-control routes, sanctions, mandatory document hashes |
| Purchase orders | `SilsilaOrders` | create/accept/fulfill/cancel with deadlines and partial quantities |
| Tracking | `SilsilaShipments` | Created → Packed → InTransit → Customs → Delivered with location + POD hashes |
| Quality | `SilsilaQuality` | auditor grades (0–100) with evidence hashes, supplier disputes |
| Settlement | `SilsilaPayments` | milestone escrow: 30% packing / 70% delivery, carrier legs, 5% late penalty, refunds |
| Cargo insurance | `SilsilaCargoInsurance` | per-shipment cover, 2% premium, 2-of-3 adjuster claims |
| Reputation | `SilsilaReputation` | on-time + grade scores (0–1000) with daily decay |
| Fees | `SilsilaTreasury` | platform fees behind a reserve floor |
| Pricing | `SilsilaOracle` | EMA price feed |
| Governance | `SilsilaGovernor` | reputation-weighted parameter voting, quorum + timelock |

## Security model

- **Milestone-gated money** — funds cannot leave escrow before the shipment
  provably reached the matching milestone
- **Role-bound actions** — only carriers/auditors move shipments, only auditors
  grade, only buyers fund and insure
- **Document hashes** — cross-border legs require export documents; delivery
  requires proof-of-delivery
- **2-of-3 adjusters** for cargo claims; timelocked, allowlisted governance

## Quick start

```bash
forge test    # 43 tests
forge build
anvil
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

## Production hardening

- IoT/hardware attestations for location proofs, licensed freight insurance,
  independent audit before real goods.

## License

MIT — see [LICENSE](../LICENSE).
