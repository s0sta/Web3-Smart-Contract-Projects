# 25 · Daman — Decentralized Insurance & Parametric Payouts

![Solidity](https://img.shields.io/badge/Solidity-0.8.26-363636?logo=solidity&logoColor=white)
![Foundry](https://img.shields.io/badge/Foundry-1.5.1-8b5cf6)
![License](https://img.shields.io/badge/License-MIT-green)
![Tests](https://img.shields.io/badge/tests-34%20green-22c55e)
![Live](https://img.shields.io/badge/Live-s0sta.com%2Fdaman-b91c1c)

> **Difficulty: ★★★★★★** · The seventh flagship · 🌐 **Live demo: [https://s0sta.com/daman](https://s0sta.com/daman)**
> — see [`frontend/README.md`](frontend/README.md)
>
> 📍 **Deployed on Sepolia: [`DamanRegistry 0x0476a7b394C8325B810790B765bDEb909dc71cA9`](https://sepolia.etherscan.io/address/0x0476a7b394C8325B810790B765bDEb909dc71cA9)** — 12 contracts live (registry, oracle, pricing, treasury, premiums, policies, claims, parametric, reinsurance, surplus, governor) · pools seeded (600,000 AED-S) and the owner's first travel policy is live — a real-world-usable mutual
> insurer: actuarial pricing, policy lifecycle, per-line pools, 2-of-3 claims,
> oracle-triggered parametric payouts, reinsurance and no-claim surplus.

## The real-world scenario

Daman ("guarantee") runs the full insurance cycle as a mutual: policyholders buy
priced covers, premiums fund per-line solvency pools, claims are settled by a
2-of-3 adjuster panel, parametric covers pay automatically when data triggers
(e.g. a flight delayed beyond 180 minutes), tail risk is ceded to a reinsurance
pool, and no-claim surplus flows back to members:

| Insurance function | Contract | Mechanism |
|---|---|---|
| Participant registry | `DamanRegistry` | policyholders/underwriters/adjusters, KYC, sanctions |
| Data | `DamanOracle` | EMA feeds + parametric conditions (thresholds on prices/measurements) |
| Actuarial pricing | `DamanPricing` | base rates × risk classes × coverage bands, pro-rata duration |
| Policies | `DamanPolicies` | quote → purchase → expiry lifecycle, per-line min/max cover |
| Solvency pools | `DamanPremiums` | per-line pools, payout gates, solvency ratios |
| Claims | `DamanClaims` | evidence hashes, 2-of-3 adjuster votes, pool payouts |
| Parametric | `DamanParametric` | oracle-triggered auto-payouts with windows and caps |
| Reinsurance | `DamanReinsurance` | 15% premium cession, attachment-point recoveries |
| Mutual surplus | `DamanSurplus` | no-claim surplus distributed pro-rata at period close |
| Fees | `DamanTreasury` | platform fee share behind a reserve floor |
| Governance | `DamanGovernor` | premium-weighted parameter voting, quorum + timelock |

## Security model

- **Data-driven payouts** — parametric covers settle on oracle conditions alone;
  no adjuster can block a triggered payout
- **Pool discipline** — every payout is gated by the line pool's solvency
- **2-of-3 panels** for claims; evidence hashes required
- **Reinsurance** protects line pools from large single losses
- **Timelocked, allowlisted governance**

## Quick start

```bash
forge test    # 34 tests
forge build
anvil
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

## Production hardening

- Licensed reinsurers, decentralized data oracles (Chainlink), independent audit.

## License

MIT — see [LICENSE](../LICENSE).
