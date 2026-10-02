# Web3 Smart Contract Projects — Complete Portfolio

> **10 complete, production-quality Solidity projects, built from scratch with Foundry — ordered from easy to hard.**
> Every contract is implemented by hand (no OpenZeppelin, no dependencies), so every single line is code I wrote and can explain.

![Solidity](https://img.shields.io/badge/Solidity-0.8.26-363636?logo=solidity&logoColor=white)
![Foundry](https://img.shields.io/badge/Foundry-1.5.1-8b5cf6)
![Tests](https://img.shields.io/badge/tests-unit%20%2B%20fuzz-brightgreen)
![License](https://img.shields.io/badge/License-MIT-green)

---

## What this repo is

A portfolio of 10 realistic smart-contract projects — the same kinds of products real clients pay for:
tokens, fundraising platforms, multisig wallets, escrow services, NFT drops, staking, vesting, DEXs, DAOs and lending protocols.

Each project is a **complete, self-contained Foundry project**:

```
01-erc20-token/
├── src/          # Solidity contracts
├── test/         # Full test suite (unit + fuzz)
├── script/       # Deployment script
├── foundry.toml
├── Makefile
├── README.md     # Docs, design decisions, security notes
└── LICENSE
```

Every project **compiles and its entire test suite passes** on Foundry 1.5.1.

---

## Why "from scratch"?

Deliberate design choice, explained honestly in each project README:

| From scratch | Trade-off |
|---|---|
| I understand 100% of every line I ship | OpenZeppelin code is battle-tested and standard in production |
| I can re-derive any primitive (ERC-20, Merkle proofs, AMM math…) on demand | I must write (and test) everything myself |
| Zero supply-chain risk, zero dependencies | Slower to build |

This repo optimizes for **deep learning and audit-readiness**. In production work I use the same
architecture but swap hand-written primitives for OpenZeppelin equivalents — each README has a
"Production hardening" section that says exactly what to swap.

---

## The Roadmap (easy → hard)

| # | Project | What it is | Core skills learned | Difficulty |
|---|---------|-----------|--------------------|:----------:|
| 01 | [ERC-20 Token](01-erc20-token) 🖥️ [live dApp](https://erc-20Token.s0sta.com) | Supply-capped token with mint, burn, pause & EIP-2612 permit | ERC-20 standard, access control, ECDSA signatures, EIP-712 | ★☆☆☆☆ |
| 02 | [Crowdfunding](02-crowdfunding) | Kickstarter-style factory: pledge ETH, goal or refund | Factory pattern, payable flows, refunds, deadlines | ★★☆☆☆ |
| 03 | [MultiSig Wallet](03-multisig-wallet) | Gnosis-style N-of-M wallet: propose, confirm, execute | Multi-party approval, replay protection, edge cases | ★★★☆☆ |
| 04 | [Escrow Service](04-escrow-service) | Buyer/seller escrow with arbitration and platform fees | State machines, dispute resolution, fee accounting | ★★★☆☆ |
| 05 | [NFT Collection](05-nft-collection) | ERC-721 drop: Merkle whitelist, mint phases, royalties | ERC-721, Merkle proofs, gas-optimized metadata | ★★★☆☆ |
| 06 | [Staking Rewards](06-staking-rewards) | Stake tokens, earn rewards, claim, emergency exit | Time-weighted reward math, accounting snapshots | ★★★★☆ |
| 07 | [Token Vesting](07-token-vesting) | Cliff + linear vesting for teams and investors | Time-based math, partial claims, schedule management | ★★★☆☆ |
| 08 | [AMM DEX](08-amm-dex) | Uniswap-V2-style constant-product AMM with router | x·y=k math, LP tokens, price impact, fees | ★★★★★ |
| 09 | [DAO Governance](09-dao-governance) | Token voting, proposals, quorum, on-chain execution | Governance lifecycle, vote counting, arbitrary calls | ★★★★★ |
| 10 | [Lending Protocol](10-lending-protocol) | Collateralized ETH lending with liquidation | Health factors, interest rates, liquidations | ★★★★★ |

### Skills you can demonstrate after this repo

- Solidity 0.8.x: custom errors, NatSpec, checked math, assembly-free gas patterns
- All major standards: ERC-20, ERC-721, EIP-2612, EIP-712, ERC-2981
- Foundry: unit tests, fuzz tests, `vm.warp`/`vm.prank`/`vm.sign`, deploy scripts, gas snapshots
- DeFi math: AMM invariants, reward accrual, vesting curves, interest & liquidation math
- Security mindset: reentrancy, replay protection, access-control matrices, rounding direction
- Real-world patterns: factory contracts, state machines, Merkle airdrops, snapshots

---

## Getting started

```bash
# 1. Install Foundry (one time)
curl -L https://foundry.paradigm.xyz | bash
foundryup

# 2. Run any project
cd 01-erc20-token
forge build      # compile
forge test       # run the full suite
make test        # same, via Makefile
forge snapshot   # gas report
```

## Deploy locally (per project)

```bash
anvil                                 # local chain in terminal 1
cd <project>
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast -vvvv
```

## Publishing to GitHub

This portfolio lives at **[github.com/s0sta/Web3-Smart-Contract-Projects](https://github.com/s0sta/Web3-Smart-Contract-Projects)**.

**Option A — one repo (this layout):** push the whole folder as-is.

```bash
git remote add origin https://github.com/s0sta/Web3-Smart-Contract-Projects.git
git push -u origin main
```

**Option B — 10 separate repos (recommended for a portfolio):** every project folder is
fully self-contained (`foundry.toml`, `Makefile`, own README and LICENSE), so:

```bash
cd 01-erc20-token
git init && git add -A && git commit -m "ERC-20 token: cap, burn, pause, permit"
gh repo create 01-erc20-token --public --source=. --push
```

Repeat for each folder. Each repo gets its own README with a link back to this master roadmap.

---

## Status

| Check | Result |
|---|---|
| Compiles on Foundry 1.5.1 / solc 0.8.26 | ✅ all 10 projects |
| Unit + fuzz test suites | ✅ **251 tests, 0 failures** across the portfolio |
| CI workflow (GitHub Actions) | ✅ runs `forge test` on every project |

Per-project test counts: 01 · 31 · 02 · 30 · 03 · 27 · 04 · 30 · 05 · 33 · 06 · 23 · 07 · 20 · 08 · 21 · 09 · 16 · 10 · 20

## Security note

These projects are **educational portfolio work** — do not deploy them to mainnet with real
funds without an independent security audit. Each README's "Security considerations" section
lists the known trade-offs of the from-scratch approach.

## License

MIT — see each project folder for its own LICENSE file.
