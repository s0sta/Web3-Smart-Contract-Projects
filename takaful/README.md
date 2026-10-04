# Takaful dApp — Frontend for s0sta.com/takaful

The hosted mutual circle for the takaful pool (Project 16): risk pools, policies,
the independent claims committee, the no-claim surplus and the qard hasan bridge.
No build step — pure HTML/CSS/JS with ethers v6 UMD.

Live: **https://s0sta.com/takaful**

## Features

- 🔌 Wallet connect, network badge, settings, read-only mode
- 🤝 **The mutual circle** — pool balance, qard hasan facility, claims paid,
  wakalah fees, operational status
- 🛡 **Risk pools** — Motor / Health / Property with contribution, claim limit and
  pooled totals; one-click join (auto-approve)
- 📋 **My policies** — your policies with coverage and claimed amounts; file a claim
- ⚖ **Claims committee** — open claims with approval counts; assessors approve/reject
  (2-of-3); anyone can fund the qard hasan bridge; the operator distributes the
  period surplus to recent non-claimers
- ✨ Coral & sky "mutual circle" light theme, layout #12
- ⚠️ Decoded errors (`PolicyExpired`, `PolicyClaimLimit`, `AlreadyVoted`,
  `InsufficientQardHasan`, `NoSurplus`, …)

## Deploy

```bash
cd 16-takaful-insurance
export DEPLOYER_PRIVATE_KEY=0x…
forge script script/Deploy.s.sol --rpc-url https://ethereum-sepolia-rpc.publicnode.com --broadcast
```

## Hosting (s0sta.com/takaful)

1. hPanel → **Files → File Manager** → `public_html/takaful`
2. Upload the **contents of `frontend/`** into it
3. Pre-filled configs: `js/config.js` + `api/config.php`
4. Verify: `https://s0sta.com/takaful/api/health.php`

## Self-test

```bash
anvil
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
cd frontend/smoke && node smoke.js
```
