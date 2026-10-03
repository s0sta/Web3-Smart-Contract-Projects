# s0sta — Web3 Security Researcher · Smart Contract Auditor · Solidity Developer

<p align="center">
  <img src="assets/hero.svg" alt="s0sta — Web3 Security Researcher · Smart Contract Auditor · Solidity Developer" width="100%" />
</p>

> **I build DeFi-grade smart contracts from scratch — and I test them like an attacker.**

![Solidity](https://img.shields.io/badge/Solidity-0.8.26-363636?logo=solidity&logoColor=white)
![Foundry](https://img.shields.io/badge/Foundry-1.5.1-8b5cf6)
![Tests](https://img.shields.io/badge/tests-520%20passing-brightgreen)
![CI](https://img.shields.io/badge/CI-19%2F19%20green-2ea44f)
![License](https://img.shields.io/badge/License-MIT-green)
![Live](https://img.shields.io/badge/Live-19%20dApps%20on%20s0sta.com-06b6d4)

---

## The repository

**19 complete protocols · 520 passing tests · 19,000+ lines of Solidity · zero external
dependencies · CI green on all 19 projects.** Every contract in this repository is written
**from scratch** — no OpenZeppelin, no libraries — then exercised the way an auditor would:
invariant tests, fuzz tests, attack PoCs, time-travel edge cases, deploy scripts, and a
production-style dApp live on Sepolia for each project.

All 19 dApps are hosted under one roof: **[s0sta.com](https://s0sta.com)** — the portal hub.

---

## Portfolio — four series, easy → hard

### 🧱 Series I · Foundations (01–05)

| # | Project | What it is | Skills demonstrated | Tests |
|---|---------|-----------|--------------------|:---:|
| 01 | [ERC-20 Token](01-erc20-token) 🖥️ [live](https://s0sta.com/erc20-token) | Supply-capped token: mint, burn, pause, EIP-2612 permit | ERC-20, ECDSA, EIP-712, access control | 34 ✅ |
| 02 | [Crowdfunding](02-crowdfunding) 🖥️ [live](https://s0sta.com/crowdfund) | Kickstarter-style factory: pledge → claim/refund, platform fees | Factory pattern, pull payments, reentrancy defense | 30 ✅ |
| 03 | [MultiSig Wallet](03-multisig-wallet) 🖥️ [live](https://s0sta.com/multisig) | Gnosis-style N-of-M treasury with arbitrary calls | Multi-party auth, execution ordering, replay safety | 27 ✅ |
| 04 | [Escrow Service](04-escrow-service) 🖥️ [live](https://s0sta.com/escrow) | Buyer/seller escrow with arbitration & fees | State machines, dispute resolution, fee accounting | 31 ✅ |
| 05 | [NFT Collection](05-nft-collection) 🖥️ [live](https://s0sta.com/nft) | ERC-721 *from scratch*: Merkle whitelist, royalties, reveal | ERC-721 internals, Merkle proofs, ERC-2981 | 33 ✅ |

### ⚙️ Series II · DeFi Mechanics (06–10)

| # | Project | What it is | Skills demonstrated | Tests |
|---|---------|-----------|--------------------|:---:|
| 06 | [Staking Rewards](06-staking-rewards) 🖥️ [live](https://s0sta.com/stake) | Synthetix-style time-weighted emissions | Accumulator math, checkpoints, O(1) rewards | 26 ✅ |
| 07 | [Token Vesting](07-token-vesting) 🖥️ [live](https://s0sta.com/vesting) | Cliff + linear vesting, revocable schedules | Time-based unlock curves, revocation accounting | 20 ✅ |
| 08 | [AMM DEX](08-amm-dex) 🖥️ [live](https://s0sta.com/dex) | Uniswap-V2-style factory/pair/router, flash swaps | `x·y=k` math, LP accounting, multi-hop routing | 21 ✅ |
| 09 | [DAO Governance](09-dao-governance) 🖥️ [live](https://s0sta.com/dao) | Snapshot voting power, quorum, on-chain execution | Checkpoint data structures, flash-loan defense | 16 ✅ |
| 10 | [Lending Protocol](10-lending-protocol) 🖥️ [live](https://s0sta.com/lend) | Collateralized lending with interest & liquidations | Health factors, compounding interest, liquidation economics | 23 ✅ |

### 🏛 Series III · Real-World Governance (11–12)

| # | Project | What it is | Skills demonstrated | Tests |
|---|---------|-----------|--------------------|:---:|
| 11 | [Owners Association Governance](11-owners-association) 🖥️ [live](https://s0sta.com/hoa) | **Dubai Law No. 6 of 2019** JOP protocol — unit registry, service charges, board & veto | Snapshot area voting, statutory quorums, reserve treasury | 48 ✅ |
| 12 | [Estate Tokenization](12-realestate-tokenization) 🖥️ [live](https://s0sta.com/estate) | **DLD/RERA** fractional ownership — property ledger, KYC shares, rental yields | Snapshot distribution epochs, maintenance reserve, compliance freezes | 20 ✅ |

### 🕌 Series IV · Islamic Finance (13–18)

| # | Project | What it is | Skills demonstrated | Tests |
|---|---------|-----------|--------------------|:---:|
| 13 | [Waqf Endowment](13-waqf-endowment) 🖥️ [live](https://s0sta.com/waqf) | Irrevocable corpus, income-only charitable distributions | Corpus-preservation invariant, donor-weighted governance, nazir board | 32 ✅ |
| 14 | [VARA Treasury](14-vara-treasury) 🖥️ [live](https://s0sta.com/vara) | Regulated VASP custody — segregation, KYC limits, capital reserve | Reserve enforcement, tier risk limits, freeze & emergency drain | 29 ✅ |
| 15 | [Sukuk Vault](15-sukuk-vault) 🖥️ [live](https://s0sta.com/sukuk) | Ijarah sukuk — certificates backed by a leased asset | Shariah income gate, profit epochs, face-value redemption | 21 ✅ |
| 16 | [Takaful Insurance](16-takaful-insurance) 🖥️ [live](https://s0sta.com/takaful) | Mutual insurance — tabarru pools, claims committee, no-claim surplus | 2-of-3 claim approvals, qard hasan bridge, snapshot surplus | 18 ✅ |
| 17 | [Murabaha Finance](17-murabaha-finance) 🖥️ [live](https://s0sta.com/murabaha) | Cost-plus trade finance — disclosed markup, installments | Charity-routed late fees, early-settlement rebate, state machine | 16 ✅ |
| 18 | [Zakat Engine](18-zakat-engine) 🖥️ [live](https://s0sta.com/zakat) | **Quran 9:60** distribution — nisab & hawl, 2.5%, eight asnaf | Ring-fenced fund, 2-of-3 committee, snapshot wealth | 22 ✅ |

### 🏢 Series V · The Full Platform (19)

| # | Project | What it is | Skills demonstrated | Tests |
|---|---------|-----------|--------------------|:---:|
| 19 | [Mawarid RWA Platform](19-mawarid-rwa) 🖥️ [live](https://s0sta.com/mawarid) | **End-to-end tokenized real estate** — registry, KYC, primary issuance, OTC exchange, rental epochs, governance, treasury, insurance (9 contracts) | Full institutional workflow: phased subscriptions, order books, snapshot epochs, token-weighted governance, reserve floors | 53 ✅ |

---

## Stats

| 19 protocols | 520 tests · 0 failures | 19,000+ Solidity lines | 0 external dependencies | CI 19/19 green | 19 live dApps |
|---|---|---|---|---|---|

Every project ships with: **from-scratch contracts + NatSpec** · **foundry.toml / remappings** ·
**unit + edge-case tests** · **deploy script** · **professional README** · **dApp frontend
(own theme + layout)** · **smoke test** · **Sepolia deployment** · **GitHub Actions CI**.

## Live dApps

One portal, 18 apps — **[s0sta.com](https://s0sta.com)** (source: [`portal/`](portal)):

`/erc20-token` · `/crowdfund` · `/multisig` · `/escrow` · `/nft` · `/stake` · `/vesting` ·
`/dex` · `/dao` · `/lend` · `/hoa` · `/estate` · `/waqf` · `/vara` · `/sukuk` · `/takaful` ·
`/murabaha` · `/zakat` · `/mawarid`

## Security methodology

<p align="center">
  <img src="assets/audit-run.svg" alt="audit run — security checklist" width="420" />
</p>

Every audit and every build in this repo follows the same discipline:

1. **Specify invariants** — what must never break (supply caps, `x·y ≥ k`, pull-payment soundness, quorum math, corpus preservation, ring-fencing)
2. **Manual review** — reentrancy, access-control matrices, rounding direction, DoS vectors, flash-loan & MEV exposure, storage layout
3. **Automated testing** — Foundry unit + fuzz suites; time-travel (`vm.warp`), signature forging (`vm.sign`), pranking
4. **Attack PoCs** — write the exploit and prove the guard blocks it (live reentrancy attack contracts in 02 & 04, flash-vote-buying test in 09)
5. **Report** — findings with severity, exploit scenario, fix and regression test

## Stack

**Languages & tooling** — Solidity 0.8.x (custom errors, NatSpec, checked math) · Foundry
(unit/fuzz/invariant tests, deploy scripts) · ethers.js v6 · Git/GitHub Actions CI ·
PHP/static hosting for the dApps

**Standards** — ERC-20 · ERC-721 · ERC-165 · ERC-2981 · EIP-2612 · EIP-712 typed data

**Security patterns** — checks-effects-interactions · pull payments · reentrancy guards ·
two-step ownership · Merkle whitelists · snapshot voting (checkpoint histories) ·
rounding-direction analysis · ring-fenced accounting · 2-of-N approval committees

**DeFi & fiqh math** — constant-product invariants & slippage · global reward accumulators ·
vesting curves · per-second compounding interest · health factors & close factors ·
statutory quorums · nisab & hawl · 2.5% zakat computation

## Verify it yourself

```bash
# one-time
curl -L https://foundry.paradigm.xyz | bash && foundryup

# any project — build AND test (CI runs both, so should you)
cd 01-erc20-token
forge build && forge test
forge snapshot   # gas report
```

GitHub Actions runs `forge build` + `forge test` on **all 19 projects** for every push —
check the checks tab on any commit.

## Working together

I'm available for smart-contract audits, protocol development and security consultations.

- 📫 **GitHub:** [@s0sta](https://github.com/s0sta)
- 🌐 **Portfolio portal:** [s0sta.com](https://s0sta.com) — one hub linking all 18 live dApps

## Security note

This repository is portfolio work demonstrating engineering and security methodology. Each
project's README documents its design decisions and known trade-offs (the from-scratch
primitives intentionally mirror OpenZeppelin semantics). Production deployments with real
funds should use battle-tested libraries and an independent audit — see
[SECURITY.md](SECURITY.md).

## License

MIT — each project folder carries its own LICENSE file.
