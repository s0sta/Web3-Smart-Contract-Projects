# 04 · TrustEscrow — Escrow Service with Arbitration & Platform Fees

![Solidity](https://img.shields.io/badge/Solidity-0.8.26-363636?logo=solidity&logoColor=white)
![Foundry](https://img.shields.io/badge/Foundry-1.5.1-8b5cf6)
![License](https://img.shields.io/badge/License-MIT-green)

> **Difficulty: ★★★☆☆** · Project 4 of the [Web3 Smart Contract Projects](../README.md) portfolio.

A complete escrow platform written **from scratch**: a buyer locks ETH for a seller; the seller
releases it on delivery; the buyer can cancel for a full refund; and a neutral arbiter resolves
disputes with an arbitrary split. The platform earns a configurable fee on every completed deal.

---

## Features

- ✅ **Full deal lifecycle** — `Active → Released | Refunded | Disputed → Resolved`
- ✅ **Arbitration** — arbiter settles disputes with any split between buyer and seller
- ✅ **Platform fee** — configurable basis points, capped at 10%, charged on release/resolve
- ✅ **Pull-based fee withdrawal** — fees stay in the contract until the owner withdraws
- ✅ **Refunds are free** — buyer cancelling an active deal pays no fee
- ✅ **Reentrancy protection** with a live attack test
- ✅ **Strict party validation** — buyer/seller/arbiter must all be distinct non-zero addresses
- ✅ **Custom errors + full NatSpec**

## Architecture

| Contract | File | Purpose |
|---|---|---|
| `Ownable` | [`src/Ownable.sol`](src/Ownable.sol) | Fee admin access control |
| `ReentrancyGuard` | [`src/ReentrancyGuard.sol`](src/ReentrancyGuard.sol) | Payout reentrancy protection |
| `TrustEscrow` | [`src/TrustEscrow.sol`](src/TrustEscrow.sol) | Deals, releases, refunds, disputes, fees |
| `DeployTrustEscrow` | [`script/Deploy.s.sol`](script/Deploy.s.sol) | Deployment + example deal |

## Flow

```
buyer.openDeal{value: X}(seller, arbiter)   ──►  ACTIVE (funds locked)
                                                   │
              ┌──────────────────┬─────────────────┴──────────────┐
              │                  │                                │
      seller.release()    buyer.refund()                dispute() by either party
      seller gets         buyer gets all back           │
      X − fee (platform   (no fee)                      ▼
      gets fee)                                    DISPUTED (frozen)
                                                        │
                                              arbiter.resolve(buyerAmount)
                                              buyer gets buyerAmount
                                              platform gets fee
                                              seller gets the remainder
```

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
| Open | deal fields/event/balance; zero deposit, self-dealing, duplicate parties, zero addresses rejected |
| Release | seller gets `amount − fee`; wrong caller, double release, release-after-refund blocked |
| Refund | buyer gets full amount, zero fee; wrong caller, double refund blocked |
| Dispute | buyer or seller only; freezes release/refund; non-active deals blocked |
| Resolve | exact three-way split (buyer/seller/fee); full buyer win; arbiter-only; bad splits rejected |
| Fees | owner withdrawal, fee cap, owner-only fee changes |
| Reentrancy | malicious seller cannot double-release via `receive()` |
| **Fuzz** | random deposits → exact release/resolve math; multi-deal accounting always balances |

## Design decisions

- **Fees only on completion.** Refunds are free so buyers are never punished for sellers
  cancelling — a deliberate product choice, documented and tested.
- **The arbiter is chosen by the buyer at open time** — in practice agreed off-chain with the
  seller first. Trust in the arbiter is the security assumption, exactly like real escrow.
- **Fee ETH stays in the escrow contract** (payouts exclude it), so `accruedFees` is always
  backed by real balance — the fuzz test proves this invariant over many deals.
- **No time-based auto-release** in this version — a deliberate scope cut; adding an
  "auto-release after N days unless disputed" path is the natural next exercise.

## Production hardening

- Swap `Ownable`/`ReentrancyGuard` for OpenZeppelin equivalents
- Add a deadline so deals can't sit in `Active` forever
- Support ERC-20 deposits (wrap an `IERC20` with `transferFrom` on `openDeal`)
- Consider an arbiter registry with reputation instead of per-deal arbitrary addresses

## Security considerations

- The arbiter can collude with either party — the protocol can't prevent it, only make the
  choice explicit and transparent. This is inherent to escrow, not a bug.
- State transitions are checked before any ETH movement (checks-effects-interactions) and
  every payout path is `nonReentrant`.

## What this project taught me

Modeling a five-state machine with per-state permissions, three-party fund splitting with
fees, dispute freezing, and proving accounting invariants with fuzzing across many deals.

## License

[MIT](LICENSE)
