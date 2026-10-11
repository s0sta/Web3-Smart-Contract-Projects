# 28 · Shifa — Decentralized Healthcare Platform

![Solidity](https://img.shields.io/badge/Solidity-0.8.26-363636?logo=solidity&logoColor=white)
![Foundry](https://img.shields.io/badge/Foundry-1.5.1-8b5cf6)
![Tests](https://img.shields.io/badge/tests-76%20green-22c55e)
![Live](https://img.shields.io/badge/Live-s0sta%20%C2%B7%20shifa-14b8a6)
![License](https://img.shields.io/badge/License-MIT-green)

> **Difficulty: ★★★★★★** · The ninth flagship — the patient owns the file:
> consent-managed medical records, electronic prescriptions, appointments,
> health insurance with a 2-of-3 medical review panel, and break-glass
> emergency access that can never be silent.

## The real-world scenario

Shifa ("healing") puts a health record under the patient's own key. Clinics write
fingerprints to the chain, the patient decides who may read them and for how
long, pharmacies dispense against a live prescription, insurers pre-authorise
and pay claims, and an emergency never blocks a doctor — it just leaves a trail
that a reviewer must confirm afterwards.

| Layer | Contract | Mechanism |
|---|---|---|
| Directory | `ShifaRegistry` | patients, doctors, clinics, pharmacists, insurers · KYC tiers, license hashes, regions, sanctions, freeze |
| Consent | `ShifaConsent` | patient grants a scope (records / prescriptions / insurance / emergency) with an expiry, revokes at will |
| Records | `ShifaRecords` | on-chain index of medical documents (content hash, kind, author, time) + amendments |
| Prescriptions | `ShifaPrescriptions` | doctor issues, pharmacy dispenses, refills counted, controlled medicines capped, expiry enforced |
| Emergency | `ShifaEmergency` | break-glass access ≤ 72h that expires by itself and needs a reviewer's verdict |
| Appointments | `ShifaAppointments` | deposits, cancellation window, completion, no-show handling, 2% fee |
| Insurance | `ShifaInsurance` | plans with yearly limits and copay · pre-authorisation · 2-of-3 review · pool pays the provider |
| Payments | `ShifaPayments` | direct payments (1.5%) and copays (0.5%), provider earnings ledger |
| Reputation | `ShifaReputation` | 0–1000 score from ratings **only after a completed visit**, decaying to neutral |
| Treasury | `ShifaTreasury` | fees behind a 20% reserve floor, guardian drain |
| Governance | `ShifaGovernor` | reputation-weighted proposals on fees, windows and review rules · quorum + timelock |

## Why the design is safe for a real clinic

- **The patient is the root of access** — `ShifaRecords.readRecord` reverts unless
  the caller is the patient, the author, or a provider holding a live consent scope.
- **No silent emergencies** — break-glass is capped at 72 hours, grants only the
  record scope, and every case waits for a reviewer's `upheld` verdict.
- **Prescriptions cannot be replayed** — refills are consumed one by one, controlled
  medicines have a hard cap, and expired prescriptions revert.
- **Claims are reviewed, not trusted** — the insurer pre-authorises a ceiling, the
  provider files, and the pool only pays after two independent reviewers agree.
- **Money is bounded** — the treasury cannot pay below its reserve; coverage can
  never exceed the plan's remaining limit.

## Quick start

```bash
forge test            # 76 tests, 11 suites
forge build
anvil
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
cd frontend/smoke && node smoke.js
```

## Live

- dApp: **https://s0sta.com/Web3-Smart-Contract-Projects/shifa/** (see [`frontend/README.md`](frontend/README.md))
- Sepolia: [`ShifaRegistry 0xB4A139e894c752765d0c2FD69CBE538f1013cA20`](https://sepolia.etherscan.io/address/0xB4A139e894c752765d0c2FD69CBE538f1013cA20)
  — 12 contracts live (registry, consent, records, prescriptions, emergency,
  appointments, treasury, insurance, payments, reputation, governor + the SAR-S
  settlement token). The owner's own record (vaccination) and prescription are on
  the books, and every address is pre-filled in `frontend/js/config.js`.

## License

MIT — see [LICENSE](../LICENSE).
