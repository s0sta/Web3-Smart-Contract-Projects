# 10 · LendVault — Collateralized Lending Protocol with Liquidations

![Solidity](https://img.shields.io/badge/Solidity-0.8.26-363636?logo=solidity&logoColor=white)
![Foundry](https://img.shields.io/badge/Foundry-1.5.1-8b5cf6)
![License](https://img.shields.io/badge/License-MIT-green)
![Live](https://img.shields.io/badge/Live-s0sta.com%2Flend-ef4444)

<p align="center">
  <img src="../assets/lending.svg" alt="LendVault — collateralized lending with liquidations" width="100%" />
</p>

> **Difficulty: ★★★★★** · Project 10 of the [Web3 Smart Contract Projects](../README.md) portfolio —
> the capstone.
>
> 🌐 **Live demo: [https://s0sta.com/lend](https://s0sta.com/lend)** — a full dApp dashboard for this protocol (see [`frontend/`](frontend/README.md)).
>
> 📍 **Deployed on Sepolia: [`LendVault 0x330FE254EbB65fFf03CA4E0814B288DffaA79e34`](https://sepolia.etherscan.io/address/0x330FE254EbB65fFf03CA4E0814B288DffaA79e34)** · USDx `0x37B0…Ac2FC` · owner `0x319899FaAAD730519B8a2Bd72d2Eba2370a9B853` · live market: 1 ETH supplied / 900 USDx borrowed

A collateralized lending protocol written **from scratch**: users deposit ETH and borrow a
stablecoin against it (66% LTV), debt compounds at 10% APR per second, and positions that
breach the 80% liquidation threshold can be liquidated — liquidators repay debt and seize
collateral at a 10% discount.

---

## Features

- ✅ **Over-collateralized borrowing** — max borrow = 66% of collateral value (LTV)
- ✅ **Per-second compound interest** — 10% APR, accrued lazily per user (gas-efficient)
- ✅ **Health factor** — live view of position safety; liquidatable below 1.0
- ✅ **Liquidations** — repay up to 50% of a bad position's debt (close factor), seize
  collateral at 110% value (liquidation bonus)
- ✅ **Vault-issued stablecoin** — only the vault mints/burns the stable (like DAI)
- ✅ **Reentrancy-guarded** on every ETH/token movement
- ✅ **Custom errors + full NatSpec**

## Architecture

| Contract | File | Purpose |
|---|---|---|
| `IERC20` | [`src/IERC20.sol`](src/IERC20.sol) | Token interface |
| `MockStable` | [`src/MockStable.sol`](src/MockStable.sol) | Vault-issued demo stablecoin |
| `LendVault` | [`src/LendVault.sol`](src/LendVault.sol) | Collateral, debt, interest, liquidations |
| `ReentrancyGuard` | [`src/ReentrancyGuard.sol`](src/ReentrancyGuard.sol) | Shared primitive |
| `DeployLendVault` | [`script/Deploy.s.sol`](script/Deploy.s.sol) | Deployment + vault/stable wiring |
| `frontend/` | [`frontend/README.md`](frontend/README.md) | The hosted dApp (s0sta.com/lend) |

## The risk math

```
maxBorrow  = collateral × PRICE × 66%          (LTV)
threshold  = collateral × PRICE × 80%          (liquidation ceiling)
health     = threshold × 1e18 / debt           (< 1e18 ⇒ liquidatable)
interest   = debt × ratePerSecond × elapsed    (10% APR, per-second compounding)
seize      = repay × 110% ÷ PRICE              (liquidator bonus)
```

A position becomes liquidatable when interest pushes its debt past the 80% ceiling —
exactly how real protocols work.

## Quickstart

```bash
forge build     # compile
forge test      # run all tests
forge snapshot  # gas report
```

## Deploy

```bash
anvil
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast -vvvv
```

## Test coverage

| Group | What it proves |
|---|---|
| Deposit/withdraw | collateral accounting; withdrawals can't break the LTV |
| Borrow/repay | exact LTV cap, mint on borrow, burn on repay, full-repay unlocks collateral |
| Interest | ~10% APR over a year; repaying accrued amounts works |
| Health | health factor math; no-debt sentinel |
| Liquidation | interest-driven breach → liquidator repays 50% and seizes at 110%; healthy/no-debt/over-close-factor rejected |
| **Fuzz** | borrows never exceed LTV; repay reduces debt exactly; liquidation seize math over random years/amounts |

## Design decisions

- **Per-user lazy accrual** — interest is compounded only when a user interacts (plus on
  demand via `currentDebt`), the standard gas-efficient approach.
- **Fixed price, no oracle.** Price feeds (Chainlink) are the obvious production upgrade;
  the README is honest about it instead of pretending a mock oracle is real.
- **Close factor caps liquidations at 50%** of a position so one liquidator can't wipe a
  position in a single transaction — Aave semantics.
- **The vault issues its own stable** — `MockStable` only lets the vault mint/burn,
  mirroring how DAI is created from collateral.

## Production hardening

- Replace the fixed price with a Chainlink price feed (and handle stale prices)
- Supply/borrow caps, interest-rate curves instead of a flat APR
- `withdraw`/`borrow`/`liquidate` should use `currentDebt` in every check (already accrued)
- Formal verification of the liquidation bonus vs. rounding direction

## Security considerations

- Liquidation profitability is guaranteed by the 10% bonus, but rounding always favors
  the protocol (seize rounds down) — tested in the fuzz suite
- No oracle = no oracle-manipulation risk *in this demo*; a real deployment adds that
  entire attack surface back
- Debt accrual is per-user; `totalDebt` is updated on every accrual, keeping global
  accounting consistent

## What this project taught me

The full lending loop: collateralization ratios, per-second compounding interest, health
factors, close factors, liquidation bonuses, and the exact economic incentives that keep
lenders, borrowers and liquidators in equilibrium.

## License

[MIT](LICENSE)
