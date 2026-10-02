# 03 · MultiSigVault — Gnosis-Style Multi-Signature Wallet

![Solidity](https://img.shields.io/badge/Solidity-0.8.26-363636?logo=solidity&logoColor=white)
![Foundry](https://img.shields.io/badge/Foundry-1.5.1-8b5cf6)
![License](https://img.shields.io/badge/License-MIT-green)
![Live](https://img.shields.io/badge/Live-multisig.s0sta.com-6366f1)

<p align="center">
  <img src="../assets/multisig.svg" alt="MultiSig Vault — N-of-M shared treasury" width="100%" />
</p>

> **Difficulty: ★★★☆☆** · Project 3 of the [Web3 Smart Contract Projects](../README.md) portfolio.
>
> 🌐 **Live demo: [https://multisig.s0sta.com](https://multisig.s0sta.com)** — a full dApp dashboard for this wallet (see [`frontend/`](frontend/README.md)).
>
> 📍 **Deployed on Sepolia: [`MultiSigWallet 0x07212677caE6aa93331d6E18205EB5898c3079f4`](https://sepolia.etherscan.io/address/0x07212677caE6aa93331d6E18205EB5898c3079f4)** · 2-of-3 · owner1 `0x319899FaAAD730519B8a2Bd72d2Eba2370a9B853`

A multi-signature wallet written **from scratch** following the classic Gnosis pattern: a group
of owners shares a treasury, and nothing leaves it until `threshold` owners confirm the
transaction. Handles ETH *and* arbitrary calls (ERC-20 transfers, contract interactions, …).

---

## Features

- ✅ **N-of-M confirmations** — configurable threshold, never 0, never more than the owner count
- ✅ **Generic transactions** — ETH transfers or any calldata (tokens, DeFi interactions)
- ✅ **Submit → confirm → execute lifecycle**, with per-owner revoke
- ✅ **Execution-failure resilience** — failed external calls roll back the `executed` flag and
  keep confirmations, so the transaction can be retried without re-signing
- ✅ **Reentrancy guard** on execution (defense-in-depth on top of Gnosis's state ordering)
- ✅ **Validation at construction** — duplicate owners and zero addresses rejected
- ✅ **Custom errors + full NatSpec**

## Architecture

| Contract | File | Purpose |
|---|---|---|
| `MultiSigWallet` | [`src/MultiSigWallet.sol`](src/MultiSigWallet.sol) | The wallet: owners, threshold, transaction queue |
| `ReentrancyGuard` | [`src/ReentrancyGuard.sol`](src/ReentrancyGuard.sol) | Execution reentrancy protection |
| `DeployMultiSig` | [`script/Deploy.s.sol`](script/Deploy.s.sol) | Deploys a 2-of-3 wallet with anvil's first three keys |
| `frontend/` | [`frontend/README.md`](frontend/README.md) | The hosted dApp (multisig.s0sta.com) |

## Flow

```
owner submits tx ──► txId = queue index
owners confirm ────► confirmationCounts[txId]++
                     │
   count ≥ threshold? ──no──► wait
                     │
                    yes
                     ▼
             executeTransaction
        executed = true  (before call!)
                     │
        call succeeds? ──yes──► emit Execution
                     │
                    no
                     ▼
        executed = false, emit ExecutionFailure
        (retry later — confirmations kept)
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
# then fund the wallet and drive it:
cast send 0xWALLET --value 1ether --private-key $ANVIL_KEY0
```

## Test coverage

| Group | What it proves |
|---|---|
| Construction | empty/duplicate/zero owners and invalid thresholds all rejected |
| Deposits | plain ETH accepted via `receive()`, event emitted |
| Submit | exact tuple fields recorded, event, non-owners blocked |
| Confirm | count/event, double-confirm blocked, unknown tx blocked |
| Revoke | drops below threshold → execution blocked; revoke after execution blocked |
| Execute | ETH moves only at threshold; double-execution blocked; non-owners blocked |
| Failure & retry | rejecting target → `ExecutionFailure`, flag rolled back, retry succeeds with same signatures |
| Threshold | changes take effect immediately; 0 / > owners rejected |
| **Generic call** | ERC-20 transfer executed purely from owner-submitted calldata |
| **Fuzz** | arbitrary ETH amounts move exactly, wallet balance stays consistent |

## Design decisions

- **Why the Gnosis model?** It's the architecture every modern Safe descends from — auditors
  and clients recognize it immediately, and it forces you to confront execution-order safety.
- **`executed = true` *before* the external call** prevents re-execution during a re-entrant
  call; on failure it rolls back so honest retries work. This is the canonical pattern.
- **Execution failure does not revert the whole transaction** — the caller pays gas and sees
  `ExecutionFailure`, matching Gnosis. Owners keep their confirmations.
- **No owner add/remove in this version** — deliberately scoped. The natural extension (with
  the hard invariant `1 ≤ threshold ≤ owners.length`) is a great follow-up exercise.

## Production hardening

- Swap `ReentrancyGuard` for OpenZeppelin's; in a real Safe, signature-based confirmations
  (EIP-712 off-chain signing, then one tx submits all sigs) replace per-owner confirm txs
- Add `addOwner`/`removeOwner`/`replaceOwner` with threshold-invariant checks
- Consider a timelock on large withdrawals for treasury use cases

## Security considerations

- The wallet executes **any** calldata the owners agree on — including `selfdestruct`-style
  hazards on the target or calls back into the wallet. Owners are the trust boundary.
- A failed external call consumes the caller's gas; retries cost gas again — by design.
- `getConfirmations` iterates owners — fine for realistic owner sets (< 50).

## What this project taught me

Multi-party authorization, transaction queuing, the executed-before-call ordering trick,
failure-path state rollback, and proving that a wallet can move ERC-20s with nothing but
user-supplied calldata.

## License

[MIT](LICENSE)
