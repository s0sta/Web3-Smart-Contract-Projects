# 15 · Sukuk Vault — Sharia-Compliant Yield Vault (Ijarah Structure)

![Solidity](https://img.shields.io/badge/Solidity-0.8.26-363636?logo=solidity&logoColor=white)
![Foundry](https://img.shields.io/badge/Foundry-1.5.1-8b5cf6)
![License](https://img.shields.io/badge/License-MIT-green)
![Tests](https://img.shields.io/badge/tests-21%20green-22c55e)
![Live](https://img.shields.io/badge/Live-s0sta.com%2Fsukuk-7fd8b0)

> **Difficulty: ★★★★★** · Flagship series #5 · 🌐 **Live demo: [https://s0sta.com/sukuk](https://s0sta.com/sukuk)**
> — see [`frontend/README.md`](frontend/README.md)
>
> 📍 **Deployed on Sepolia: [`SukukVault 0xAb1b72EEA7D7842dfA48e7d44B7C21E153DA0bd7`](https://sepolia.etherscan.io/address/0xAb1b72EEA7D7842dfA48e7d44B7C21E153DA0bd7)** · AED-S `0xD780…0238` · "Green Ijarah Sukuk — Series 1" (1,000 × 100 AED-S, 365-day maturity) · 250 certificates held, Q1 income approved and distributed — 675 AED-S claimable — a sukuk (Islamic bond) on-chain using the
> **ijarah structure**: investor capital acquires a leased income-generating asset; the
> lease income — not interest — is the profit, approved by a Shariah board and distributed
> pro-rata; at maturity the asset is sold and the certificates redeem at face value.

## The real-world scenario

Sukuk are AAOIFI-governed certificates that securitize an underlying asset. The profit is
**rent from the asset** (ijarah), never riba (interest), which is why the income needs a
Shariah-board approval gate and the principal must return to investors at maturity:

| Sukuk concept (AAOIFI) | On-chain implementation |
|---|---|
| Certificate issuance | `issueSeries(name, faceValue, totalCertificates, maturity, asset, indicativeProfit)` |
| Underlying asset | named in the series; the issuer sells it at maturity into the redemption pool |
| Ijarah income | issuer records lease income — held **pending Shariah approval** |
| Shariah supervision | a Shariah board role approves income sources before distribution |
| Profit smoothing | a share of approved income is withheld into a profit reserve |
| Distributions | **epochs**: pro-rata by certificates held at each epoch's snapshot block |
| Maturity redemption | holders redeem certificates at face value from the asset-sale proceeds |
| No early redemption | certificates run to maturity (liquidity comes from the secondary market) |
| Guardian | can freeze a series — never seize the asset proceeds |

## Contracts

| Contract | Path | Responsibility |
|---|---|---|
| `SukukVault` | [`src/SukukVault.sol`](src/SukukVault.sol) | series issuance, certificates, income gate, epochs, redemption |
| `AccessControl` / `Checkpoints` / `MockStable` | [`src/`](src) | shared from-scratch primitives |

## Security model

- **Riba-free by construction** — income is approved by the Shariah role before it can
  reach the distribution pool; the smoothing reserve is withheld first
- **Snapshot entitlements** — certificates at each epoch's snapshot block determine the
  claim, so a sale can never redirect past profit
- **Redemption discipline** — payout is capped by the redemption pool (asset-sale
  proceeds) and the remaining distribution pool; principal never comes from other
  investors' certificates
- **Exact supply** — purchases cannot exceed the series' certificate count; CEI ordering

## Quick start

```bash
forge test    # 21 tests
forge build
anvil
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

## Production hardening

- A real asset oracle/title registry for the underlying, an external Shariah-supervisory
  attestation service for income approval, independent audit.

## License

MIT — see [LICENSE](../LICENSE).
