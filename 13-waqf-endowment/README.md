# 13 · Waqf Endowment Governance — Sharia-Compliant Endowment Protocol

![Solidity](https://img.shields.io/badge/Solidity-0.8.26-363636?logo=solidity&logoColor=white)
![Foundry](https://img.shields.io/badge/Foundry-1.5.1-8b5cf6)
![License](https://img.shields.io/badge/License-MIT-green)
![Tests](https://img.shields.io/badge/tests-31%20green-22c55e)
![Live](https://img.shields.io/badge/Live-s0sta.com%2Fwaqf-065f46)

> **Difficulty: ★★★★★** · Flagship series #3 · 🌐 **Live demo: [https://s0sta.com/waqf](https://s0sta.com/waqf)**
> — see [`frontend/README.md`](frontend/README.md)
>
> 📍 **Deployed on Sepolia: [`WaqfVault 0x3dc6d47de5f14f562b4bee02417d2fa51cab1c19`](https://sepolia.etherscan.io/address/0x3dc6d47de5f14f562b4bee02417d2fa51cab1c19)** · governor `0xa2de…8c15` · registry `0x3689…f6555` · "Amanah Education Waqf" — 10,000 AED-S corpus endowed, first 1,000 AED-S income distributed — the *waqf* (endowment) institution on-chain:
> an **irrevocable corpus** that can never be spent, **income-only distributions** to
> registered beneficiaries, donor-weighted governance, and a nazir (trustee) board.

## The real-world scenario

A waqf — the Islamic endowment practiced across the UAE under the Awqaf authorities — dedicates
an asset in perpetuity: the *corpus* must remain intact forever, and only its *yield* benefits
the named causes (schools, mosques, hospitals, the needy). This protocol encodes that structure:

| Waqf concept | On-chain implementation |
|---|---|
| Corpus irrevocability | `endow()` is the ONLY entry point to the corpus — no withdrawal, spend, or collateral path exists; `totalCorpus` only grows |
| Yield (income) | nazir board records income (`recordIncome`) into a pool tracked separately from the corpus |
| Beneficiaries | `BeneficiaryRegistry`: named causes with weights in bps (must sum to 10,000) |
| Distribution | pro-rata to weights; **the corpus is untouched** — distributions draw only from the income pool |
| Administration | an operational fund (e.g., 10% of income) — spendable only through governance |
| Governance | donors vote with their **endowed contributions** (snapshot at proposal creation); a 3-nazir board confirms; timelock before execution |
| Emergency | guardian can freeze distributions — never the corpus |
| Audit trail | every endowment, income, distribution, weight change is an on-chain event |

**Sharia-compliance posture**: no interest mechanisms anywhere in the protocol (income is
recorded from permissible sources), the corpus is structurally preserved, and distributions
go to registered charitable causes — the on-chain implementation mirrors how awqaf are
administered and audited today.

## Contracts

| Contract | Path | Responsibility |
|---|---|---|
| `WaqfVault` | [`src/WaqfVault.sol`](src/WaqfVault.sol) | corpus, income pool, distributions, operational fund, freeze |
| `BeneficiaryRegistry` | [`src/BeneficiaryRegistry.sol`](src/BeneficiaryRegistry.sol) | beneficiaries, weights, deactivation, distribution targets |
| `WaqfGovernor` | [`src/WaqfGovernor.sol`](src/WaqfGovernor.sol) | donor-weighted proposals, nazir confirmations, timelock, execution |
| `AccessControl` / `Checkpoints` / `MockStable` | [`src/`](src) | shared from-scratch primitives |

## Security model

- **The corpus-preservation invariant** — no code path can reduce `totalCorpus`; governance
  targets are allowlisted (registry, vault, governor) and can only reach the operational fund
- **Snapshot at block − 1** for proposing and snapshot-at-creation for voting — no flash-endow
  then vote
- **Two independent gates** — donor quorum AND 2-of-3 nazir confirmations must both pass
- **Timelock** between vote end and execution; CEI in `execute()`
- **Structural selector validation** — e.g., `OperationalSpend` must call
  `vault.spendOperational`

## Quick start

```bash
forge test    # 31 tests
forge build
anvil
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

## Production hardening

- A real yield source (Sukuk/tokenized rental income) feeding `recordIncome` via an oracle or
  keeper; independent Sharia-supervisory-board review; audit.

## License

MIT — see [LICENSE](../LICENSE).
