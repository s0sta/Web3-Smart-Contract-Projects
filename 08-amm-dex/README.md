# 08 · SimpleSwap — Uniswap-V2-Style Constant-Product AMM DEX

![Solidity](https://img.shields.io/badge/Solidity-0.8.26-363636?logo=solidity&logoColor=white)
![Foundry](https://img.shields.io/badge/Foundry-1.5.1-8b5cf6)
![License](https://img.shields.io/badge/License-MIT-green)

> **Difficulty: ★★★★★** · Project 8 of the [Web3 Smart Contract Projects](../README.md) portfolio.

A complete automated market maker written **from scratch**, following Uniswap V2's architecture:
a factory that creates pools for any token pair, LP tokens, a 0.3% swap fee that accrues to
liquidity providers, multi-hop routing with slippage protection and flash swaps.

---

## Features

- ✅ **Factory** — permissionless pools for any ERC-20 pair, canonical sorted-token order
- ✅ **Constant-product invariant** — `x·y = k` enforced on every swap with the 0.3% fee
- ✅ **LP tokens** — mint/burn liquidity proportionally; `MINIMUM_LIQUIDITY` lock at genesis
- ✅ **Router** — add/remove liquidity with optimal quoting, `swapExactTokensForTokens`,
  `swapTokensForExactTokens`, multi-hop paths, slippage minimums and deadlines
- ✅ **Flash swaps** — borrow tokens, do something, repay in the same transaction
- ✅ **V2-style reentrancy lock**, `skim`/`sync` maintenance functions, balance-delta accounting
- ✅ **Custom errors + full NatSpec**

## Architecture

| Contract | File | Purpose |
|---|---|---|
| `AMMFactory` | [`src/AMMFactory.sol`](src/AMMFactory.sol) | Creates + indexes pools |
| `AMMPair` | [`src/AMMPair.sol`](src/AMMPair.sol) | The pool: LP token, invariant, swaps, fees |
| `AMMRouter` | [`src/AMMRouter.sol`](src/AMMRouter.sol) | User-facing liquidity + swap entry point |
| `AMMLibrary` | [`src/AMMLibrary.sol`](src/AMMLibrary.sol) | Pure pricing math (`getAmountOut`, `quote`, paths) |
| `ERC20` | [`src/ERC20.sol`](src/ERC20.sol) | The LP token implementation |
| `DeployAMM` | [`script/Deploy.s.sol`](script/Deploy.s.sol) | Deploys + seeds a GLD/USD pool |

## The core math

```
swap:   amountOut = (amountIn × 997 × reserveOut) / (reserveIn × 1000 + amountIn × 997)
check:  (balance0×1000 − in0×3) × (balance1×1000 − in1×3) ≥ reserve0 × reserve1 × 1000²
liquidity: LP = min(Δx·totalSupply/x, Δy·totalSupply/y)   (sqrt(x·y) − 1000 at genesis)
```

The fee stays inside the pool, so `k` strictly grows with every swap — the fuzz suite asserts
this invariant over arbitrary swap sizes.

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
| Factory | sorted pair creation, order-independent lookup, duplicates/identical tokens rejected |
| Liquidity | `sqrt(x·y)−1000` genesis LP, pro-rata second provider, optimal quoting, mins & deadlines |
| Swap | exact quote match, `k` grows (fee accrual), min-out & deadline enforcement, multi-hop A→B→C |
| Remove | full share returned incl. fees (measured at original price), min enforcement |
| Flash swap | borrow + repay in callback; exactly the fee remains in the pool |
| Maintenance | `skim` returns stray tokens, `sync` adopts donations |
| **Fuzz** | invariant never breaks; add/remove round-trip (dust tolerance); price impact grows with size |

## Design decisions

- **Uniswap V2 architecture on purpose.** It is the reference design every DEX audit starts
  from — balance-delta accounting, the `unlocked` reentrancy flag, sorted token order.
- **No ETH pairs, no oracles, no protocol fee** — deliberately scoped out and listed as
  extensions; the token-pair core is fully faithful to V2.
- **Order re-sorting matters.** The router reorders `burn`'s outputs when the caller's token
  order differs from the pool's sorted order — a real bug class caught by the test suite.

## Production hardening

- This code follows V2 but is **not audited** — in production use battle-tested forks
- Add CREATE2 `pairFor` precomputation, price oracles, and protocol-fee switches
- Consider flash-loan-aware invariant tests and `foundry-invariant` handlers

## Security considerations

- The `lock` modifier and effects-first ordering make reentrancy impossible; the invariant
  check makes under-collateralized swaps revert
- Flash swaps are a feature, not a bug — the invariant check guarantees repayment
- Fee-on-transfer tokens would break the balance-delta accounting (V2 has the same limitation)

## What this project taught me

The complete AMM lifecycle: invariant math, LP share accounting, fee accrual mechanics,
multi-hop routing, flash-loan callbacks, and the subtle token-ordering bugs that audits exist
to catch.

## License

[MIT](LICENSE)
