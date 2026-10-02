# 01 · NovaToken — Supply-Capped ERC-20 with EIP-2612 Permit

![Solidity](https://img.shields.io/badge/Solidity-0.8.26-363636?logo=solidity&logoColor=white)
![Foundry](https://img.shields.io/badge/Foundry-1.5.1-8b5cf6)
![License](https://img.shields.io/badge/License-MIT-green)

> **Difficulty: ★☆☆☆☆** · Project 1 of the [Web3 Smart Contract Projects](../README.md) portfolio.

A complete ERC-20 token written **from scratch** (no OpenZeppelin): a 100M hard supply cap,
owner-controlled minting and burning, an emergency pause switch, two-step ownership, and
EIP-2612 `permit` for gasless approvals.

---

## Features

- ✅ **Full ERC-20** — `transfer`, `approve`, `transferFrom`, `balanceOf`, `allowance`, `totalSupply`
- ✅ **Hard supply cap** — `MAX_SUPPLY = 100,000,000` tokens; minting can never exceed it
- ✅ **Owner mint / burn** — controlled token supply, with `burnFrom` for allowances
- ✅ **Emergency pause** — freezes *all* token movement instantly (transfer, mint, burn, permit)
- ✅ **EIP-2612 permit** — off-chain signed approvals (EIP-712 typed data), one signature = approve + transferFrom in a single tx
- ✅ **Two-step ownership transfer** — no more losing a contract to a typo'd address
- ✅ **Infinite allowance sentinel** — `type(uint256).max` allowances never decrease (gas saving for trusted spenders)
- ✅ **Custom errors + full NatSpec** — cheap reverts, self-documenting code

## Architecture

| Contract | File | Purpose |
|---|---|---|
| `Ownable` | [`src/Ownable.sol`](src/Ownable.sol) | Single owner, two-step transfer, renounce |
| `NovaToken` | [`src/Token.sol`](src/Token.sol) | ERC-20 core + cap, mint/burn, pause, permit |
| `DeployNovaToken` | [`script/Deploy.s.sol`](script/Deploy.s.sol) | Deployment script |
| `NovaTokenTest` | [`test/Token.t.sol`](test/Token.t.sol) | Full unit + fuzz suite |

## Quickstart

```bash
forge build     # compile
forge test      # run all tests
forge test -vv  # verbose output
forge snapshot  # gas report
```

## Deploy

```bash
# Terminal 1 — local chain
anvil

# Terminal 2 — deploy with anvil's first key (or set PRIVATE_KEY in .env)
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast -vvvv
```

## Test coverage

| Group | What it proves |
|---|---|
| Metadata | name/symbol/decimals/supply/owner initialized correctly |
| Mint | owner-only, cap enforced, zero-address rejected, events emitted |
| Transfer | balances move, events, insufficient balance, zero-address rejection |
| Allowances | approve → transferFrom spends allowance, infinite sentinel, insufficient allowance |
| Burn | supply symmetry, over-burn rejection, `burnFrom` allowance spend |
| Pause | owner-only, blocks all movement, unpause restores |
| Ownership | two-step flow, wrong-acceptor rejection, renounce locks admin |
| Permit | valid signature sets allowance + burns nonce, replay fails, wrong signer fails, expiry enforced |
| **Fuzz** | random amounts transfer symmetrically; supply never exceeds cap; random permit values |

## Design decisions

- **Permit, why?** Gasless UX is how real products (Uniswap, Aave) let users approve + spend in one transaction. It also demonstrates EIP-712 typed-data hashing, the same machinery used by every DeFi protocol.
- **Pause blocks mint too.** OpenZeppelin's `ERC20Pausable` freezes *all* movement — I follow the same semantics so "paused" has one unambiguous meaning.
- **Two-step ownership** exists because the #1 real-world ownership bug is a typo'd transfer. The new owner must prove they can sign.
- **Checked math everywhere.** Solidity 0.8 default overflow checks make `totalSupply + amount > MAX_SUPPLY` safe by construction.

## Production hardening

If deploying with real funds, swap in battle-tested equivalents:

- `Ownable` → OpenZeppelin v5 `Ownable2Step`
- ERC-20 core + permit → OpenZeppelin `ERC20Permit`
- Consider `ecrecover`'s high-s malleability (harmless here — nonces prevent replay — but wallets verify canonical s anyway)
- Get an independent audit before mainnet

## Security considerations

- `approve` front-running: a user changing an allowance can be raced. The standard mitigation (`increaseAllowance`/`decreaseAllowance`) is intentionally left out to keep this first project focused — a good exercise is adding it.
- `ecrecover` returns `address(0)` for invalid signatures — explicitly rejected.
- Renounce + pause are irreversible by design; document this to users.

## What this project taught me

The full ERC-20 state machine, event semantics (`Transfer` from/to `address(0)` for mint/burn),
access-control design, EIP-712 typed-data signing end-to-end, and how to build a professional
Foundry test suite with fuzzing.

## License

[MIT](LICENSE)
