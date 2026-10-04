# Silsila dApp — Frontend for s0sta.com/silsila

The hosted control tower for the trade network (Project 24): business
registration, purchase orders, shipment tracking, milestone payments, cargo
insurance and governance. No build step — pure HTML/CSS/JS with ethers v6 UMD.

Live: **https://s0sta.com/silsila**

## Features

- 🔌 Wallet connect, network badge, settings, read-only mode
- 🚚 **Control strip** — your role, entities, escrowed funds, premiums, reputation
- 📦 **Orders** — register a business, create and accept purchase orders
- 🛰 **Shipments** — create shipments, advance milestones, deliver with POD
- 💵 **Payments & governance** — fund escrow, insure cargo, vote on proposals
- ✨ Graphite & signal orange "control tower" dark theme, layout #20
- ⚠️ Decoded errors (`WrongRole`, `MissingPod`, `OverFulfillment`,
  `NotDelivered`, `Timelocked`, …)

## Deploy

```bash
cd 24-silsila-supplychain
export DEPLOYER_PRIVATE_KEY=0x…
forge script script/Deploy.s.sol --rpc-url https://ethereum-sepolia-rpc.publicnode.com --broadcast
```

## Hosting (s0sta.com/silsila)

1. hPanel → **Files → File Manager** → `public_html/silsila`
2. Upload the **contents of `frontend/`** into it
3. Pre-filled configs: `js/config.js` + `api/config.php`
4. Verify: `https://s0sta.com/silsila/api/health.php`

## Self-test

```bash
anvil
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
cd frontend/smoke && node smoke.js
```
