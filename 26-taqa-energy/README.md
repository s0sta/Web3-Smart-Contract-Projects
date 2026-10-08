# 26 · Taqa — Decentralized Energy & Carbon Markets

![Solidity](https://img.shields.io/badge/Solidity-0.8.26-363636?logo=solidity&logoColor=white)
![Foundry](https://img.shields.io/badge/Foundry-1.5.1-8b5cf6)
![License](https://img.shields.io/badge/License-MIT-green)
![Tests](https://img.shields.io/badge/tests-31%20green-22c55e)
![Live](https://img.shields.io/badge/Live-s0sta.com%2Ftaqa-65a30d)

> **Difficulty: ★★★★★★** · The eighth flagship · 🌐 **Live demo: [https://s0sta.com/taqa](https://s0sta.com/taqa)**
> — see [`frontend/README.md`](frontend/README.md)
>
> 📍 **Deployed on Sepolia: [`TaqaRegistry 0xc183fA1628d408D63b754aA9F5A8bAFF0167fb25`](https://sepolia.etherscan.io/address/0xc183fA1628d408D63b754aA9F5A8bAFF0167fb25)** — 12 contracts live (registry, oracle, meters, certificates, carbon, treasury, market, P2P, retirement, compliance, governor) · the owner's 25 kW solar meter with 10,000 kWh attested and 10 RECs minted is live — a real-world-usable energy
> market: renewable energy certificates, carbon credits, P2P energy trading and
> double-retirement-proof green claims.

## The real-world scenario

Taqa ("energy") digitizes the renewable-energy economy: producers register
meters, auditors attest production, certificates mint per 1,000 kWh, trade on
an escrowed market, and retire against named green claims; carbon credits mint
with vintages; neighbors trade energy P2P at live tariffs; every unit can only
be retired once:

| Energy function | Contract | Mechanism |
|---|---|---|
| Participant registry | `TaqaRegistry` | producers/consumers/auditors/retailers, KYC, sanctions |
| Data | `TaqaOracle` | EMA energy/carbon prices + production telemetry |
| Meters | `TaqaMeters` | meter registration, telemetry, auditor attestation (1 REC = 1,000 kWh) |
| Certificates | `TaqaCertificates` | REC minting per attested production, transfers |
| Carbon | `TaqaCarbon` | verified emission reductions with vintages |
| Exchange | `TaqaMarket` | escrowed limit orders for RECs/credits with fees |
| P2P trading | `TaqaP2P` | kWh offers at live tariffs, net-metering batches |
| Green claims | `TaqaRetirement` | double-retirement-proof retirements against claims |
| Rules | `TaqaCompliance` | energy-zone allowlists, sanctions |
| Fees | `TaqaTreasury` | fee engine behind a reserve floor |
| Governance | `TaqaGovernor` | certificate-weighted voting, quorum + timelock |

## Security model

- **Auditor-gated minting** — certificates and credits only exist on attested
  production or verified reductions
- **No double counting** — retirement burns the asset; a unit can never be
  claimed twice
- **Escrowed exchange** — resting orders hold the real assets
- **Zone compliance** on every trade leg; timelocked, allowlisted governance

## Quick start

```bash
forge test    # 31 tests
forge build
anvil
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

## Production hardening

- Certified meter hardware attestations, registry-grade auditors (I-REC/Verra
  style), independent audit.

## License

MIT — see [LICENSE](../LICENSE).
