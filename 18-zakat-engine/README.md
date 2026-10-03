# 18 · Zakat Engine — Quran 9:60 Distribution Protocol

![Solidity](https://img.shields.io/badge/Solidity-0.8.26-363636?logo=solidity&logoColor=white)
![Foundry](https://img.shields.io/badge/Foundry-1.5.1-8b5cf6)
![License](https://img.shields.io/badge/License-MIT-green)
![Tests](https://img.shields.io/badge/tests-22%20green-22c55e)
![Live](https://img.shields.io/badge/Live-s0sta.com%2Fzakat-e8a317)

> **Difficulty: ★★★★★** · Flagship series #8 · 🌐 **Live demo: [https://s0sta.com/zakat](https://s0sta.com/zakat)**
> — see [`frontend/README.md`](frontend/README.md)
>
> 📍 **Deployed on Sepolia: [`ZakatEngine 0x2B5fF4f15DdccA62233B06225b34DE5f93718495`](https://sepolia.etherscan.io/address/0x2B5fF4f15DdccA62233B06225b34DE5f93718495)** · registry `0xc1f7…9989` · AED-S `0xA829…b64c` · "Bayt al-Mal" — nisab 4,000, wealth 250,000 declared, first recipients registered — the zakat obligation on-chain: payers
> declare wealth, the engine computes the 2.5% due once the nisab has been held for a
> full lunar year (hawl), and the ring-fenced fund is distributed ONLY to the eight
> asnaf (Quran 9:60) through a 2-of-3 committee.

## The real-world scenario

Zakat — one of the five pillars — is 2.5% of qualifying wealth held above the nisab
(85g of gold) for one lunar year, distributed to eight specific categories. This
protocol encodes the fiqh of zakat:

| Zakat concept | On-chain implementation |
|---|---|
| Nisab | configurable threshold (85g gold equivalent in the payment token) |
| Hawl (lunar year) | the hawl clock starts when wealth crosses the nisab and resets when it falls below |
| 2.5% computation | `ZAKAT_RATE_BPS = 250` — exact, auditable |
| Self-assessment | payers declare wealth with snapshot history |
| The eight asnaf | `AsnafRegistry` — Fuqara, Masakin, Amil, Muallaf, Riqab, Gharimin, Fi Sabilillah, Ibn Sabil — with allocation ratios (bps) |
| Recipients | KYC'd per category with proof-of-eligibility hashes |
| Ring-fencing | the zakat fund can ONLY flow to registered asnaf recipients; even the committee cannot divert it |
| Committee | 2-of-3 approvals for every disbursement; the Amil share covers administration |
| Guardian | can pause — never touch the fund |

## Contracts

| Contract | Path | Responsibility |
|---|---|---|
| `ZakatEngine` | [`src/ZakatEngine.sol`](src/ZakatEngine.sol) | wealth, nisab/hawl, 2.5% due, ring-fenced fund, disbursements |
| `AsnafRegistry` | [`src/AsnafRegistry.sol`](src/AsnafRegistry.sol) | the 8 categories, allocations, KYC'd recipients |
| `AccessControl` / `Checkpoints` / `MockStable` | [`src/`](src) | shared from-scratch primitives |

## Security model

- **Ring-fenced by construction** — the only outward transfer from the fund is
  `_executeDisbursement`, which pays a registered, active asnaf recipient
- **2-of-3 committee** with on-chain votes and records; double votes revert
- **Hawl integrity** — wealth snapshots make the lunar-year clock verifiable
- **Allocation caps** — committee allocations are bounded at 10,000 bps total

## Quick start

```bash
forge test    # 22 tests
forge build
anvil
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

## Production hardening

- Wealth attestation oracles (bank/brokerage proofs), recipient assessment
  workflows, independent Shariah audit.

## License

MIT — see [LICENSE](../LICENSE).
