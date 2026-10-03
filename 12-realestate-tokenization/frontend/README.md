# Estate Tokenization dApp — Frontend for s0sta.com/estate

The hosted dashboard for the tokenized estate protocol (Project 12): the DLD/RERA
fractional-ownership pattern — property ledger, KYC shares, rental distributions.
No build step — pure HTML/CSS/JS with ethers v6 UMD.

Live: **https://s0sta.com/estate**

## Features

- 🔌 Wallet connect, network badge, settings, read-only mode
- 🏢 **The Property** — appraisal, share supply, issued shares, live/frozen status,
  your balance, your KYC status, transfer form
- 💸 **Rental Distributions** — total rent, pending pool, epoch count, maintenance
  fund with reserve ratio, your claimable yield, distribute + claim buttons,
  rent payment form (auto-approve)
- 🛠 **Management** — file appraisals, spend the maintenance fund, KYC whitelist
  add/remove, property freeze, reserve-ratio tuning (role-aware)
- ✨ Terracotta & sea-teal "tower prospectus" light theme — three-column desk,
  static background, element motion only
- ⚠️ Decoded errors (`NotWhitelisted`, `Frozen`, `ExceedsSupply`, `NothingToClaim`, …)

## Deploy

```bash
cd 12-realestate-tokenization
export DEPLOYER_PRIVATE_KEY=0x…
forge script script/Deploy.s.sol --rpc-url https://ethereum-sepolia-rpc.publicnode.com --broadcast
```

## Hosting (s0sta.com/estate)

1. hPanel → **Files → File Manager** → `public_html/estate`
2. Upload the **contents of `frontend/`** into it
3. Pre-filled configs: `js/config.js` + `api/config.php`
4. Verify: `https://s0sta.com/estate/api/health.php`

## Self-test

```bash
anvil
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
cd frontend && node smoke/smoke.js
```
