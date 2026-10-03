# 17 · Murabaha Finance — Sharia-Compliant Trade Finance

![Solidity](https://img.shields.io/badge/Solidity-0.8.26-363636?logo=solidity&logoColor=white)
![Foundry](https://img.shields.io/badge/Foundry-1.5.1-8b5cf6)
![License](https://img.shields.io/badge/License-MIT-green)
![Tests](https://img.shields.io/badge/tests-16%20green-22c55e)
![Live](https://img.shields.io/badge/Live-s0sta.com%2Fmurabaha-2e4f91)

> **Difficulty: ★★★★★** · Flagship series #7 · 🌐 **Live demo: [https://s0sta.com/murabaha](https://s0sta.com/murabaha)**
> — see [`frontend/README.md`](frontend/README.md)
>
> 📍 **Deployed on Sepolia: [`MurabahaFinancing 0xa293EBb6e86718f5A2E9c53403E38f698824e751`](https://sepolia.etherscan.io/address/0xa293EBb6e86718f5A2E9c53403E38f698824e751)** · AED-S `0x6aE5…7BC8` · "Gulf Trade Finance" — trade #0 live (12,000 + 10% markup, 12 installments, delivered) — murabaha (cost-plus trade finance): the
> financier buys an asset at cost, sells it at a **disclosed fixed markup**, and the buyer
> repays in installments — with late penalties routed to charity, never to the financier.

## The real-world scenario

Murabaha is the most widely used Islamic financing structure: the bank purchases the goods
from the supplier (title first passes to the bank), then sells them to the client at cost
plus an agreed markup, payable over time. The markup is disclosed and fixed — no
compounding, no variable interest:

| Murabaha concept | On-chain implementation |
|---|---|
| Disclosed cost + markup | recorded at request time; profit capped at 50% of cost |
| Shariah approval | every trade must be approved by the Shariah board before funding |
| Supplier purchase | the financier pays the supplier directly (title passes to the financier) |
| Delivery confirmation | the buyer confirms receipt — repayment starts only after delivery |
| Installment schedule | on-chain due dates: first due + fixed interval, per-installment amounts |
| **Late penalties → charity** | missed installments incur a fee that is paid to a charity address — the financier structurally cannot earn it |
| Early settlement rebate | the buyer may prepay the remaining installments at a discount on the remaining markup |
| Default & recovery | beyond the tolerated missed-installment threshold the trade defaults; the financier recovers collected funds |
| Documentation | supplier invoice hash + asset description on-chain for the Shariah board and auditors |

## Contracts

| Contract | Path | Responsibility |
|---|---|---|
| `MurabahaFinancing` | [`src/MurabahaFinancing.sol`](src/MurabahaFinancing.sol) | trade lifecycle, installments, charity penalties, rebates, recovery |
| `AccessControl` / `MockStable` | [`src/`](src) | shared from-scratch primitives |

## Security model

- **Riba-free by construction** — the markup is fixed at request time; late fees flow to
  charity; the early-settlement rebate only ever reduces the financier's profit
- **State machine** — Requested → Approved → Purchased → Delivered → Repaying → Settled/
  Defaulted; every transition validates the previous state
- **Guarantor** — installment payments may come from the guarantor; recovery is
  financier-gated; CEI ordering throughout

## Quick start

```bash
forge test    # 16 tests
forge build
anvil
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

## Production hardening

- Collateral registry and valuation oracles, credit-scoring inputs, dispute arbitration
  layer, independent audit.

## License

MIT — see [LICENSE](../LICENSE).
