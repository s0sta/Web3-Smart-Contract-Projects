# 23 · Huwiyya — Decentralized Identity & Credentials Platform

![Solidity](https://img.shields.io/badge/Solidity-0.8.26-363636?logo=solidity&logoColor=white)
![Foundry](https://img.shields.io/badge/Foundry-1.5.1-8b5cf6)
![License](https://img.shields.io/badge/License-MIT-green)
![Tests](https://img.shields.io/badge/tests-30%20green-22c55e)
![Live](https://img.shields.io/badge/Live-s0sta.com%2Fhuwiyya-4338ca)

> **Difficulty: ★★★★★★** · The fifth flagship · 🌐 **Live demo: [https://s0sta.com/huwiyya](https://s0sta.com/huwiyya)**
> — see [`frontend/README.md`](frontend/README.md)
>
> 📍 **Deployed on Sepolia: [`HuwiyyaRegistry 0x77701d73b4615715f3767E5ca308EB07Eb0A8Ae9`](https://sepolia.etherscan.io/address/0x77701d73b4615715f3767E5ca308EB07Eb0A8Ae9)** — 10 contracts live (registry, schemas, treasury, credentials, attestations, reputation, gates, recovery, governor) · the owner's DID with a live KYC attestation is registered — a real-world-usable identity
> stack: DIDs, verifiable credentials with selective disclosure, attestations,
> reputation, access gates and social recovery.

## The real-world scenario

Huwiyya ("identity") implements the W3C/EIDAS credential workflow on-chain: a DID
owns keys, trusted issuers issue verifiable credentials against schemas, holders
prove single claims through Merkle proofs **without revealing the rest** (e.g.
prove "born before 2006" without showing the exact date), trusted attestors build
reputation, services gate access on credential + reputation policies, and lost
keys are recovered socially:

| Identity function | Contract | Mechanism |
|---|---|---|
| DID ledger | `HuwiyyaRegistry` | key records, rotation, delegation, freeze, revocation |
| Schemas | `HuwiyyaSchema` | versioned claim-field definitions |
| Selective disclosure | `HuwiyyaMerkle` | from-scratch Merkle proofs |
| Credentials | `HuwiyyaCredentials` | issue/revoke/present verifiable credentials with claims roots |
| Attestations | `HuwiyyaAttestations` | trusted attestors, type weights, evidence hashes, expiry |
| Reputation | `HuwiyyaReputation` | weighted scores with decay, named bands, checkpoints |
| Access gates | `HuwiyyaGates` | policies: credentials + reputation + disclosed-claim minimums |
| Social recovery | `HuwiyyaRecovery` | 2-of-3 guardian key rotation with a delay |
| Fees | `HuwiyyaTreasury` | issuance fees behind a reserve floor |
| Governance | `HuwiyyaGovernor` | reputation-weighted parameter voting, quorum + timelock |

## Security model

- **Zero-reveal proofs** — presenting a claim leaks nothing but the claim itself
- **Revocation everywhere** — issuers revoke credentials, attestors revoke
  attestations, compliance freezes DIDs; all checks consult live status
- **Guardian-delayed recovery** — key rotation needs quorum AND a timelock
- **Weighted trust** — unlisted attestors count fully by default; operators can
  discount untrusted ones
- **Timelocked, allowlisted governance**

## Quick start

```bash
forge test    # 30 tests
forge build
anvil
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

## Production hardening

- Zero-knowledge circuits for full claim privacy, decentralized key storage,
  independent audit before real credentials.

## License

MIT — see [LICENSE](../LICENSE).
