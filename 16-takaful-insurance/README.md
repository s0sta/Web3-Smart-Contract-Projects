# 16 · Takaful — Sharia-Compliant Mutual Insurance

![Solidity](https://img.shields.io/badge/Solidity-0.8.26-363636?logo=solidity&logoColor=white)
![Foundry](https://img.shields.io/badge/Foundry-1.5.1-8b5cf6)
![License](https://img.shields.io/badge/License-MIT-green)
![Tests](https://img.shields.io/badge/tests-18%20green-22c55e)
![Live](https://img.shields.io/badge/Live-s0sta.com%2Ftakaful-ff7f66)

> **Difficulty: ★★★★★** · Flagship series #6 · 🌐 **Live demo: [https://s0sta.com/takaful](https://s0sta.com/takaful)**
> — see [`frontend/README.md`](frontend/README.md)
>
> 📍 **Deployed on Sepolia: [`TakafulPool 0xe0528967d4bB5C4Ccd02d64cEa3b7D57367dA238`](https://sepolia.etherscan.io/address/0xe0528967d4bB5C4Ccd02d64cEa3b7D57367dA238)** · AED-S `0xf720…6e28` · "Amanah Mutual" — Motor/Health/Property pools live, your Motor policy #0 issued (450 AED-S net pooled) — takaful (Islamic mutual insurance) on the
> **wakalah model**: participants donate contributions (tabarru) into a shared pool,
> claims are decided by an independent committee, and the underwriting surplus is
> returned to those who did not claim.

## The real-world scenario

Conventional insurance is impermissible in Islamic finance because of gharar (excessive
uncertainty) and riba. Takaful replaces it with **mutuality**: the pool belongs to the
participants, the operator is a wakeel (agent) earning a disclosed fee, and the surplus
is returned to the community:

| Takaful concept | On-chain implementation |
|---|---|
| Tabarru (donation) | `joinPool` — a contribution per risk pool (Motor / Health / Property) |
| Wakalah fee | a disclosed operator fee (e.g., 10%) withheld from every contribution |
| Policy | coverage window + per-policy claim limit, issued at contribution time |
| Claims committee | claims need **2-of-3 independent assessor approvals** before payout |
| Surplus (no-claim benefit) | at each period boundary, the underwriting surplus is distributed
  pro-rata to **non-claiming participants** by contribution snapshots |
| Qard hasan | an interest-free bridge facility (donations) covers pool deficiencies,
  repaid from future contributions |
| Investment income | permissible returns recorded by the operator feed the surplus |
| Guardian | can pause the pool — never seize participant funds |

## Contracts

| Contract | Path | Responsibility |
|---|---|---|
| `TakafulPool` | [`src/TakafulPool.sol`](src/TakafulPool.sol) | pools, policies, claims, committee votes, surplus, qard hasan |
| `AccessControl` / `Checkpoints` / `MockStable` | [`src/`](src) | shared from-scratch primitives |

## Security model

- **Mutual by construction** — the operator can only withhold the disclosed fee; the
  pool's balance is distributed by the contract's rules, not the operator's discretion
- **2-of-N claim approvals** with on-chain votes and reasons — no single assessor can
  pay a claim; rejections close the claim once two approvals become unreachable
- **Surplus math is snapshot-based** — a participant who transfers or claims during a
  period cannot capture the surplus twice (`period + 1` sentinel, CEI ordering)
- **Qard hasan is ring-fenced** — the facility can only bridge claim shortfalls and is
  repaid from contributions; the operator cannot withdraw it

## Quick start

```bash
forge test    # 18 tests
forge build
anvil
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

## Production hardening

- Actuarial pricing input, re-takaful (reinsurance) layers, a real assessor
  registry with dispute arbitration, independent audit.

## License

MIT — see [LICENSE](../LICENSE).
