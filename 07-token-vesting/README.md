# 07 · TokenVesting — Cliff + Linear Vesting for Teams & Investors

![Solidity](https://img.shields.io/badge/Solidity-0.8.26-363636?logo=solidity&logoColor=white)
![Foundry](https://img.shields.io/badge/Foundry-1.5.1-8b5cf6)
![License](https://img.shields.io/badge/License-MIT-green)

> **Difficulty: ★★★☆☆** · Project 7 of the [Web3 Smart Contract Projects](../README.md) portfolio.

A token vesting contract written **from scratch**: the owner creates funded, revocable schedules
for beneficiaries — nothing vests before a cliff, then the grant unlocks linearly until the end.
The standard tool for team allocations, investor unlocks and advisor grants.

---

## Features

- ✅ **Cliff + linear vesting** — `vested = total × (now − cliff) / (end − cliff)`
- ✅ **Funded schedules** — tokens are pulled into the contract at creation, claims always backed
- ✅ **Revocable** — owner can revoke: unvested tokens return to the owner, vested stay claimable
- ✅ **Pull-based claims** — beneficiaries withdraw whenever they like, O(1)
- ✅ **One schedule per beneficiary** enforced at creation
- ✅ **Reentrancy-guarded claims + custom errors + full NatSpec**

## Architecture

| Contract | File | Purpose |
|---|---|---|
| `IERC20` / `MockToken` | [`src/`](src) | Token interface + demo token |
| `TokenVesting` | [`src/TokenVesting.sol`](src/TokenVesting.sol) | Schedules, vesting math, claims, revocation |
| `Ownable` / `ReentrancyGuard` | [`src/`](src) | Shared primitives |
| `DeployTokenVesting` | [`script/Deploy.s.sol`](script/Deploy.s.sol) | 1M VEST, 1-year cliff, 3-year linear example |

## The vesting curve

```
vested
  │                             ┌──────────── 100% at end, forever
  │                           ╱
  │                         ╱
  │                       ╱
  │ ┌─────────────────── 0% through the cliff
──┴────────────────────────────────────────────► time
   start           cliff = start + cliffDuration          end = cliff + vestingDuration
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
| Creation | tokens pulled at creation, params stored, owner-only, bad params rejected, duplicates rejected |
| Math | zero before start/cliff (incl. the exact cliff boundary), linear at midpoint, full at end and beyond |
| Claims | partial then full claims, pre-cliff/no-schedule/nothing-new reverts |
| Revocation | unvested returns to owner, vested stays claimable, nothing vests after revoke |
| **Fuzz** | the vesting curve is monotonic and capped; claims never exceed vested; revocation accounting always balances |

## Design decisions

- **Funded, not promised.** Depositing the grant at creation means a claim can never fail for
  lack of funds — the strongest possible guarantee for a beneficiary.
- **Revocation keeps vested tokens.** The beneficiary keeps exactly what the curve granted
  them; only the unvested remainder returns. `totalAmount` is rewritten to the vested amount,
  so `releasable` stays honest forever after.
- **`start` is a parameter**, so schedules can be backdated (common for investors who
  committed earlier) or future-dated (grants starting next month).

## Production hardening

- Swap primitives for OpenZeppelin; use a real ERC-20
- Batch creation + a `createSchedules` loop for airdrop-style team onboarding
- Consider a claimable-by-anyone `claimFor(beneficiary)` for custodial UX

## Security considerations

- The owner can revoke at any time — a trust assumption beneficiaries must accept.
  Documented, tested, and standard in team vesting.
- `vestedAmount` uses the schedule's stored timestamps, immune to reentrancy (pure view math).

## What this project taught me

Time-based unlock curves, cliff semantics and their exact boundary behavior, revocable-grant
accounting, and the investor/team vesting flows behind every token launch.

## License

[MIT](LICENSE)
