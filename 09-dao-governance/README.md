# 09 · GovDAO — Token Governance with Snapshot Voting & On-Chain Execution

![Solidity](https://img.shields.io/badge/Solidity-0.8.26-363636?logo=solidity&logoColor=white)
![Foundry](https://img.shields.io/badge/Foundry-1.5.1-8b5cf6)
![License](https://img.shields.io/badge/License-MIT-green)
![Live](https://img.shields.io/badge/Live-dao.s0sta.com-b91c1c)

<p align="center">
  <img src="../assets/dao.svg" alt="Senate DAO — token governance with snapshot voting" width="100%" />
</p>

> **Difficulty: ★★★★★** · Project 9 of the [Web3 Smart Contract Projects](../README.md) portfolio.
>
> 🌐 **Live demo: [https://dao.s0sta.com](https://dao.s0sta.com)** — a full dApp dashboard for this governor (see [`frontend/`](frontend/README.md)).
>
> 📍 **Deployed on Sepolia: [`Governor 0x9a9Cb0c2Ac2A08d3A4590Aaa1B5637A16dDBcC48`](https://sepolia.etherscan.io/address/0x9a9Cb0c2Ac2A08d3A4590Aaa1B5637A16dDBcC48)** · GOV `0xEf96…47c60` · two live proposals, one already with 910k for / 60k against

A complete DAO written **from scratch**: a governance token with per-block voting-power
snapshots (OpenZeppelin-"Votes"-style checkpoints), proposals with a threshold + quorum,
time-boxed voting, and automatic execution of arbitrary on-chain calls.

---

## Features

- ✅ **Historical voting power** — every balance change is checkpointed per block; any past
  block can be queried with binary search
- ✅ **Flash-loan-proof voting** — votes weigh the token balance *at the proposal's snapshot
  block*, so tokens bought after the proposal add nothing (proven by a live test)
- ✅ **Proposal threshold** — need a minimum past balance to propose
- ✅ **Quorum** — basis points of the snapshot total supply (4% default)
- ✅ **On-chain execution** — successful proposals run arbitrary calls (incl. ETH transfers)
- ✅ **Cancel flow** — proposers can withdraw proposals while voting is open
- ✅ **Custom errors + full NatSpec**

## Architecture

| Contract | File | Purpose |
|---|---|---|
| `GovToken` | [`src/GovToken.sol`](src/GovToken.sol) | ERC-20 + per-block voting-power checkpoints |
| `Governor` | [`src/Governor.sol`](src/Governor.sol) | Proposals, voting, quorum, execution |
| `DeployDAO` | [`script/Deploy.s.sol`](script/Deploy.s.sol) | 1M GOV, 3-day voting, 10k threshold, 4% quorum |
| `frontend/` | [`frontend/README.md`](frontend/README.md) | The hosted dApp (dao.s0sta.com) |

## Lifecycle

```
propose ──► ACTIVE (3 days, snapshot = proposal block)
               │ vote(for/against) with snapshot weight
               ▼
        deadline passes
               │
   for > against AND for ≥ quorum?
        │                │
        ▼                ▼
    SUCCEEDED        DEFEATED
        │
   execute() ──► runs targets[i].call{value}(calldatas[i])
                 (proposer can cancel() while ACTIVE)
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
| Snapshots | historical balances resolve correctly per block; future blocks rejected |
| Propose | threshold enforced, proposal fields + Active state, empty/mismatched/zero-target rejected |
| Vote | weights counted, double-voting blocked, deadline enforced |
| **Flash-vote-buy** | tokens bought after the snapshot add zero voting power |
| Execute | passing proposals change real on-chain state; ETH transfers; quorum and majority gates; single execution |
| Cancel | proposer-only, active-only |
| **Fuzz** | random vote splits always match the exact state-machine outcome |

## Design decisions

- **Checkpoint snapshots over live balances.** The #1 governance vulnerability is flash-loan
  vote buying; snapshotting at proposal creation closes it, and the test proves the attack fails.
- **Quorum in basis points of snapshot supply** — resilient to supply changes, like
  OpenZeppelin's `GovernorVotesQuorumFraction`.
- **Proposers need past votes too** — checked at `block.number − 1` so mint-then-propose fails.
- **Execution flips state before calls** (checks-effects-interactions), so a proposal can
  never be re-executed through a re-entrant callback.

## Production hardening

- Add delegation (vote with others' tokens), `voteWithReason`, timelocks before execution
- Use OpenZeppelin Governor for production DAOs; this implementation is faithful in spirit
  but deliberately compact
- Consider emergency veto/multisig guardrails alongside pure token voting

## Security considerations

- Zero-weight votes are allowed (standard); they can't influence outcomes
- `getPastVotes` allows querying the current block (relaxed vs OpenZeppelin) — cross-block
  vote buying is still impossible, which is the real threat model

## What this project taught me

Historical balance data structures (checkpoints + binary search), proposal state machines,
quorum/threshold governance math, and the flash-loan vote-buying attack — the reason every
real DAO snapshots.

## License

[MIT](LICENSE)
