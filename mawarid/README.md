# Mawarid dApp — Frontend for s0sta.com/mawarid

The hosted exchange floor for the RWA platform (Project 19): invest in the primary
phase, trade on the OTC secondary market, claim rental epochs and participate in
asset governance. No build step — pure HTML/CSS/JS with ethers v6 UMD.

Live: **https://s0sta.com/mawarid**

## Features

- 🔌 Wallet connect, network badge, settings, read-only mode
- 🏛 **Asset ticker** — the asset, appraisal, shares issued, rent distributed, lifecycle status
- 💼 **Invest** — your shares, claimable rent and KYC status; subscribe to the primary
  phase (auto-approve), claim allocations, claim rental income
- 📊 **The exchange** — volume, fees and the fee rate; open sell orders with fill/cancel;
  place limit sell orders (auto share-approve)
- ⚖ **Governance** — proposals with lifecycle states, vote for/against, execute; propose
  an appraisal; record rental income (manager) and distribute the pool
- ✨ Petroleum & copper "exchange floor" light theme, layout #15
- ⚠️ Decoded errors (`CapExceeded`, `SelfFill`, `NothingToClaim`, `Timelocked`,
  `TransferBlocked`, …)

## Deploy

```bash
cd 19-mawarid-rwa
export DEPLOYER_PRIVATE_KEY=0x…
forge script script/Deploy.s.sol --rpc-url https://ethereum-sepolia-rpc.publicnode.com --broadcast
```

## Hosting (s0sta.com/mawarid)

1. hPanel → **Files → File Manager** → `public_html/mawarid`
2. Upload the **contents of `frontend/`** into it
3. Pre-filled configs: `js/config.js` + `api/config.php`
4. Verify: `https://s0sta.com/mawarid/api/health.php`

## Self-test

```bash
anvil
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
cd frontend/smoke && node smoke.js
```
