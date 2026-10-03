# 02 · CrowdFund — Kickstarter-Style Crowdfunding Platform

![Solidity](https://img.shields.io/badge/Solidity-0.8.26-363636?logo=solidity&logoColor=white)
![Foundry](https://img.shields.io/badge/Foundry-1.5.1-8b5cf6)
![License](https://img.shields.io/badge/License-MIT-green)
![Live](https://img.shields.io/badge/Live-s0sta.com/crowdfund-10b981)

<p align="center">
  <img src="../assets/crowdfund.svg" alt="CrowdFund — decentralized crowdfunding platform" width="100%" />
</p>

> **Difficulty: ★★☆☆☆** · Project 2 of the [Web3 Smart Contract Projects](../README.md) portfolio.
>
> 🌐 **Live demo: [https://s0sta.com/crowdfund](https://s0sta.com/crowdfund)** — a full dApp dashboard for this platform (see [`frontend/`](frontend/README.md)).
>
> 📍 **Deployed on Sepolia: [`CrowdFundFactory 0x49Ed445AB73b0397B8946c6BCDCa4bFcF04C9FdB`](https://sepolia.etherscan.io/address/0x49Ed445AB73b0397B8946c6BCDCa4bFcF04C9FdB)** · owner `0x319899FaAAD730519B8a2Bd72d2Eba2370a9B853` · example campaign [`0xf2455A06…3a6E`](https://sepolia.etherscan.io/address/0xf2455A060eF697878d86463c7e7AFeBd69293a6E)

A complete crowdfunding platform written **from scratch**: anyone creates a campaign with a
funding goal and deadline; backers pledge ETH; if the goal is met the creator claims the funds
(minus a configurable platform fee), otherwise every backer pulls their own refund.

---

## Features

- ✅ **Factory pattern** — one `CrowdFundFactory` deploys and indexes unlimited campaigns
- ✅ **Full lifecycle state machine** — `Active → Successful | Failed` derived from time + goal
- ✅ **Pull-based refunds** — backers withdraw their own funds; no push-to-everyone DoS trap
- ✅ **Platform fee** — configurable basis-points fee on every successful campaign (frozen per campaign)
- ✅ **Reentrancy protection** — hand-written `ReentrancyGuard`, plus a live attack test
- ✅ **Checks-effects-interactions** — entitlements zeroed before ETH is sent
- ✅ **Creator can't pledge to their own campaign** — prevents self-funding games
- ✅ **Custom errors + full NatSpec**

## Architecture

| Contract | File | Purpose |
|---|---|---|
| `Ownable` | [`src/Ownable.sol`](src/Ownable.sol) | Fee-setter / fee-withdrawer access control |
| `ReentrancyGuard` | [`src/ReentrancyGuard.sol`](src/ReentrancyGuard.sol) | Hand-written reentrancy protection |
| `CrowdFundCampaign` | [`src/CrowdFundCampaign.sol`](src/CrowdFundCampaign.sol) | Pledge → claim/refund state machine |
| `CrowdFundFactory` | [`src/CrowdFundFactory.sol`](src/CrowdFundFactory.sol) | Campaign deployment, fees, registry |
| `DeployCrowdFund` | [`script/Deploy.s.sol`](script/Deploy.s.sol) | Deploys factory + example campaign |
| `frontend/` | [`frontend/README.md`](frontend/README.md) | The hosted dApp (s0sta.com/crowdfund) |

## Flow

```
            pledge ETH ────────────┐
            (until deadline)       │
                                   ▼
                    ┌──────────────────────────┐
                    │  deadline passes          │
                    └──────────────────────────┘
                     │                    │
        total ≥ goal │                    │ total < goal
                     ▼                    ▼
              SUCCESSFUL               FAILED
        creator.claim()         every backer refunds
        (goal + overfunding,    themselves via pull
         minus platform fee)    pattern
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
| Factory | registration, fee caps (≤10%), owner-only fee ops, zero-goal rejection |
| Pledging | accumulation, zero pledge, creator exclusion, deadline boundary (inclusive) |
| Status | Active/Successful/Failed transitions at exactly the right moments |
| Claim | creator gets `total − fee`, fee credited to factory, double-claim blocked |
| Refund | exact refunds, double-refund blocked, non-backers blocked, success blocks refund |
| Reentrancy | a malicious backer contract fails to double-withdraw via `receive()` |
| **Fuzz** | arbitrary pledge → exact refund; arbitrary overfund → creator gets `amount − fee`; 5-backer end-to-end |

## Design decisions

- **Pull, don't push.** If refunds were a loop over every backer, one stuck address could brick
  the whole campaign. Each backer withdraws their own — O(1) and DoS-proof.
- **Fees physically move to the factory.** `creditFees` is `payable` and the campaign forwards
  the fee ETH with the call, so nothing is ever stranded in a campaign contract; the owner
  then withdraws from the factory (pull).
- **Fee frozen at creation.** Campaign economics are predictable for creators; changing the
  platform fee only affects future campaigns.
- **`totalPledged` never decreases on refund** — it's history; entitlements (`pledged`) zero out.
  The contract's actual ETH balance is the source of truth for claims.
- **Reentrancy guard + effects-first** is belt-and-suspenders: the guard makes the attack
  impossible even if the ordering were ever refactored wrong.

## Production hardening

- Swap `Ownable`/`ReentrancyGuard` for OpenZeppelin equivalents (identical API)
- Use a pull-based fee model per campaign creator if campaigns are expected to be adversarial
- Consider `try/catch` around fee credit or cap fees at the factory level (done here via `MAX_FEE_BPS`)
- Add a `refundAll`-style governance escape hatch for emergency halts

## Security considerations

- The campaign deliberately **allows over-funding** (Kickstarter semantics). Document to creators
  that excess is claimable, not refunded.
- `status()` uses `<=` at the deadline: pledging at the exact boundary is allowed — tested.
- Factory trusts its own campaigns to call `creditFees` — the `isCampaign` whitelist enforces that.

## What this project taught me

Factory deployment patterns, a real state machine with time boundaries, the pull-refund DoS
lesson, fee accounting, and writing a reentrancy attack test that actually exercises the exploit.

## License

[MIT](LICENSE)
