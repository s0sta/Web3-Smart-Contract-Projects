# JOP Owners Association dApp — Frontend for s0sta.com/hoa

The hosted dashboard for the flagship governance protocol (Project 11): a Dubai
Law No. 6 of 2019-inspired owners association, portable to HOA/condominium
frameworks in any country. No build step — pure HTML/CSS/JS with ethers v6 UMD.

Live: **https://s0sta.com/hoa**

## Features

- 🔌 Wallet connect, network badge, settings, read-only mode
- 🏛 **The Chamber** — proposal ballots with lifecycle seals (Review / Active / Timelock /
  Succeeded / Executed / Defeated / Canceled / Vetoed), for/against area-weight bars,
  quorum readouts and vote countdowns (descriptions recovered from the propose
  transactions' calldata — no off-chain indexer)
- 🗳 **Role-aware actions** — vote, board fast-track, compliance veto (with on-chain note),
  proposer/board cancel, execute (timelock enforced)
- 📜 **Propose** — all seven proposal types with the on-chain target allowlist
- ⚖️ **Voting power** — owned area + proxy power, threshold, delegation with expiry
- 🏢 **Building register** — every unit with area, owner and charge debt; pay your
  service charges in AED-S (auto-approve)
- 🏦 **Treasury card** — balance, reserve ratio, total paid out, charge rate, unit count
- 🎩 **Roles card** — the board seats and your own roles
- ✨ Navy & brass "registry office" theme — static background, element motion only
- ⚠️ Decoded errors (`BelowProposalThreshold`, `Timelocked`, `InvalidTargets`, …)

## Deploy

```bash
cd 11-owners-association
export DEPLOYER_PRIVATE_KEY=0x…
forge script script/Deploy.s.sol --rpc-url https://ethereum-sepolia-rpc.publicnode.com --broadcast
```

## Hosting (s0sta.com/hoa)

1. hPanel → **Files → File Manager** → `public_html/hoa`
2. Upload the **contents of `frontend/`** into it
3. Pre-filled configs: `js/config.js` + `api/config.php`
4. Verify: `https://s0sta.com/hoa/api/health.php`

## Self-test

```bash
anvil
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
cd frontend && GOVERNOR=0x… node smoke/smoke.js
```
