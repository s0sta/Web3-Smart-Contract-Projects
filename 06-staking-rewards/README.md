# 06 · StakeVault — ERC-20 Staking with Time-Weighted Rewards

![Solidity](https://img.shields.io/badge/Solidity-0.8.26-363636?logo=solidity&logoColor=white)
![Foundry](https://img.shields.io/badge/Foundry-1.5.1-8b5cf6)
![License](https://img.shields.io/badge/License-MIT-green)
![Live](https://img.shields.io/badge/Live-s0sta.com/stake-14b8a6)

<p align="center">
  <img src="../assets/staking.svg" alt="StakeVault — time-weighted staking rewards" width="100%" />
</p>

> **Difficulty: ★★★★☆** · Project 6 of the [Web3 Smart Contract Projects](../README.md) portfolio.
>
> 🌐 **Live demo: [https://s0sta.com/stake](https://s0sta.com/stake)** — a full dApp dashboard for this vault (see [`frontend/`](frontend/README.md)).
>
> 📍 **Deployed on Sepolia: [`StakeVault 0xacc9353CecE7344064b20060A712C7B6A8f8450e`](https://sepolia.etherscan.io/address/0xacc9353CecE7344064b20060A712C7B6A8f8450e)** · STAKE `0x2B12…5085` · REWARD `0x9d54…0010` · 1,000,000 REW over 30 days · 1,500 STAKE already staked

A staking vault written **from scratch** using the classic Synthetix `StakingRewards`
architecture: users stake one ERC-20 and earn a second ERC-20 at a fixed global emission rate,
pro-rated by their share of the pool — with per-user checkpoints so accounting stays fair
whenever anyone enters, exits or claims.

---

## Features

- ✅ **Fair time-weighted rewards** — global `rewardPerToken` accumulator + per-user checkpoints
- ✅ **Owner-funded emissions** — `startRewards(amount, duration)` spreads tokens over time
- ✅ **Mid-period top-ups** — leftover rewards roll over into the new rate (tested)
- ✅ **Stake / withdraw / claim / exit / emergency-withdraw** lifecycle
- ✅ **Emergency withdraw forfeits rewards** (MasterChef-style) — principal out, dust documented
- ✅ **Precision-safe 1e18-scaled math**, no per-user timestamps (O(1) updates)
- ✅ **Reentrancy-guarded** token movements + custom errors + full NatSpec

## Architecture

| Contract | File | Purpose |
|---|---|---|
| `IERC20` | [`src/IERC20.sol`](src/IERC20.sol) | Minimal token interface |
| `StakeVault` | [`src/StakeVault.sol`](src/StakeVault.sol) | The staking + rewards engine |
| `MockToken` | [`src/MockToken.sol`](src/MockToken.sol) | Mintable ERC-20 for demos/tests |
| `Ownable` / `ReentrancyGuard` | [`src/`](src) | Shared primitives |
| `DeployStakeVault` | [`script/Deploy.s.sol`](script/Deploy.s.sol) | Deploys tokens + vault, funds 1M REW over 30 days |
| `frontend/` | [`frontend/README.md`](frontend/README.md) | The hosted dApp (s0sta.com/stake) |

## The core invariant

```
rewardPerToken = stored + (elapsed × rewardRate × 1e18) / totalStaked
earned(user)   = balance × (rewardPerToken − userRewardPerTokenPaid) / 1e18 + unclaimed
```

Every balance-changing call updates the global accumulator **and** the caller's checkpoint
first, so rewards are always settled up to that exact moment. No per-user timestamps needed —
O(1) gas for any number of stakers.

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
| Staking | tokens pulled, balances recorded, zero/without-approval paths |
| Reward math | single staker gets the full rate; proportional split; late stakers earn only after entry |
| Claiming | payout + reset; **checkpoint prevents double-counting** after a claim |
| Withdraw | tokens returned, rewards preserved; over-withdraw/zero rejected |
| Emergency | principal returned, rewards forfeited and left as documented dust |
| Emissions | owner-only funding, zero-duration rejection, mid-period rollover math |
| **Fuzz** | linear earnings over random time; proportional split; withdraw+restake keeps accounting sound |

## Design decisions

- **Synthetix over MasterChef.** The global-accumulator model is the industry standard and its
  fairness is provable — the fuzz tests encode that proof.
- **Emergency withdraw forfeits, not steals.** Forfeited rewards are left in the vault as dust
  rather than re-distributed — simpler, predictable, and standard practice.
- **Rate = amount / duration** truncates sub-wei-per-second dust; tests assert with tolerance
  and the README documents it.

## Production hardening

- Swap `Ownable`/`ReentrancyGuard` for OpenZeppelin; use a real audited ERC-20
- Consider `recoverERC20` for accidental token sends (with reentrancy care)
- Add a timelock or governance on `startRewards` if emissions are protocol-owned

## Security considerations

- `startRewards` trusts the owner to fund before stakers earn — if the owner underfunds,
  claims fail at the token level. In production, fund-then-notify ordering matters.
- The vault holds all staked + reward tokens; a compromised owner can only affect emission
  parameters, not user balances.

## What this project taught me

Time-weighted reward accrual with global accumulators, checkpoint discipline, integer-precision
reward math, and how the same architecture powers Synthetix, Curve gauges and countless farms.

## License

[MIT](LICENSE)
