# VARA Treasury dApp — Frontend for s0sta.com/vara

The hosted regulatory console for the VASP treasury (Project 14): segregated client
assets, KYC-tiered limits, capital reserve, compliance powers and the guardian
emergency path. No build step — pure HTML/CSS/JS with ethers v6 UMD.

Live: **https://s0sta.com/vara**

## Features

- 🔌 Wallet connect, network badge, settings, read-only mode
- 🛡 **Status strip** — operational/paused, client liabilities, house equity,
  reserve ratio + recovery address, your role
- 👤 **Your account** — balances (AED-S + ETH), KYC tier, daily limits & usage,
  deposit/withdraw flows (auto-approve)
- ⚖ **Compliance console** — set KYC tiers, sanction/clear, freeze + force-transfer
  50% to recovery, approve counterparties
- 🛡 **Guardian & operations** — pause/unpause, emergency drain, reserve tuning,
  recovery address
- ✨ Charcoal & amber "regulatory console" dark theme, layout #10
- ⚠️ Decoded errors (`WithdrawalLimit`, `ReserveBreach`, `Blocked`,
  `NotApprovedCounterparty`, …)

## Deploy

```bash
cd 14-vara-treasury
export DEPLOYER_PRIVATE_KEY=0x…
forge script script/Deploy.s.sol --rpc-url https://ethereum-sepolia-rpc.publicnode.com --broadcast
```

## Hosting (s0sta.com/vara)

1. hPanel → **Files → File Manager** → `public_html/vara`
2. Upload the **contents of `frontend/`** into it
3. Pre-filled configs: `js/config.js` + `api/config.php`
4. Verify: `https://s0sta.com/vara/api/health.php`

## Self-test

```bash
anvil
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
cd frontend/smoke && node smoke.js
```
