# Rahala dApp — Frontend for s0sta.com/rahala

The hosted payments console for the network (Project 22): send escrowed payments,
convert FX, register invoices and vote on network parameters. No build step —
pure HTML/CSS/JS with ethers v6 UMD.

Live: **https://s0sta.com/rahala**

## Features

- 🔌 Wallet connect, network badge, settings, read-only mode
- 💸 **Send** — instant / timelocked / milestone payments with auto-approve
- 💱 **FX** — AED-S ↔ USD conversions at live oracle rates
- 🧾 **Invoices & governance** — register invoices; vote on and execute proposals
- ✨ Deep sea & pearl "payments console" light theme, layout #18
- ⚠️ Decoded errors (`TransferLimit`, `RegionBlocked`, `Slippage`,
  `ReleaseLocked`, `Timelocked`, …)

## Deploy

```bash
cd 22-rahala-payments
export DEPLOYER_PRIVATE_KEY=0x…
forge script script/Deploy.s.sol --rpc-url https://ethereum-sepolia-rpc.publicnode.com --broadcast
```

## Hosting (s0sta.com/rahala)

1. hPanel → **Files → File Manager** → `public_html/rahala`
2. Upload the **contents of `frontend/`** into it
3. Pre-filled configs: `js/config.js` + `api/config.php`
4. Verify: `https://s0sta.com/rahala/api/health.php`

## Self-test

```bash
anvil
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
cd frontend/smoke && node smoke.js
```
