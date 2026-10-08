# Taqa dApp — Frontend for s0sta.com/taqa

The hosted energy grid for the market (Project 26): meters, renewable energy
certificates, carbon credits, P2P energy and green-claim retirement. No build
step — pure HTML/CSS/JS with ethers v6 UMD.

Live: **https://s0sta.com/taqa**

## Features

- 🔌 Wallet connect, network badge, settings, read-only mode
- ⚡ **Grid strip** — tariff, REC/carbon supply, your holdings and retirements
- 🔋 **Meters & certificates** — register as a producer, register meters, mint RECs
- 🏪 **Market** — list and fill REC/carbon orders with auto-approve
- 🌱 **P2P, retirement & governance** — post kWh offers, retire certificates
  against claims, vote on proposals
- ✨ Volt green & solar gold "energy grid" dark theme, layout #22
- ⚠️ Decoded errors (`InsufficientAssets`, `SelfFill`, `ZoneBlocked`,
  `InsufficientKwh`, `Timelocked`, …)

## Deploy

```bash
cd 26-taqa-energy
export DEPLOYER_PRIVATE_KEY=0x…
forge script script/Deploy.s.sol --rpc-url https://ethereum-sepolia-rpc.publicnode.com --broadcast
```

## Hosting (s0sta.com/taqa)

1. hPanel → **Files → File Manager** → `public_html/taqa`
2. Upload the **contents of `frontend/`** into it
3. Pre-filled configs: `js/config.js` + `api/config.php`
4. Verify: `https://s0sta.com/taqa/api/health.php`

## Self-test

```bash
anvil
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
cd frontend/smoke && node smoke.js
```
