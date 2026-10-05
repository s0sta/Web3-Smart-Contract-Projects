# Daman dApp — Frontend for s0sta.com/daman

The hosted claims desk for the insurance mutual (Project 25): quotes and policy
purchases, claims, parametric covers and governance. No build step — pure
HTML/CSS/JS with ethers v6 UMD.

Live: **https://s0sta.com/daman**

## Features

- 🔌 Wallet connect, network badge, settings, read-only mode
- 🛡 **Coverage strip** — travel pool, premiums, fees, your policies, condition state
- 🧾 **Get covered** — live quotes and policy purchases per line and risk class
- 📑 **Policies & claims** — your covers with statuses; file evidence-backed claims
- 🌦 **Parametric & governance** — buy oracle-triggered covers; vote on proposals
- ✨ Protection red & mint "claims desk" dark theme, layout #21
- ⚠️ Decoded errors (`CoverOutOfBounds`, `InsufficientPool`, `WindowClosed`,
  `CapExceeded`, `Timelocked`, …)

## Deploy

```bash
cd 25-daman-insurance
export DEPLOYER_PRIVATE_KEY=0x…
forge script script/Deploy.s.sol --rpc-url https://ethereum-sepolia-rpc.publicnode.com --broadcast
```

## Hosting (s0sta.com/daman)

1. hPanel → **Files → File Manager** → `public_html/daman`
2. Upload the **contents of `frontend/`** into it
3. Pre-filled configs: `js/config.js` + `api/config.php`
4. Verify: `https://s0sta.com/daman/api/health.php`

## Self-test

```bash
anvil
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
cd frontend/smoke && node smoke.js
```
