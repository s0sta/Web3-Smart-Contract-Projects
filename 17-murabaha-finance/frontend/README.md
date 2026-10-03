# Murabaha dApp — Frontend for s0sta.com/murabaha

The hosted trade desk for the murabaha book (Project 17): request financing,
track the lifecycle, pay installments, settle early with a rebate — late fees
always flow to charity. No build step — pure HTML/CSS/JS with ethers v6 UMD.

Live: **https://s0sta.com/murabaha**

## Features

- 🔌 Wallet connect, network badge, settings, read-only mode
- 📝 **Request financing** — supplier, guarantor, cost, disclosed markup,
  installments and the asset description
- 📒 **The trade book** — lifecycle steppers (Requested → Approved → Purchased →
  Delivered → Repaying → Settled/Defaulted/Rejected), repayment progress bars,
  missed installments and charity-fee totals
- ⚙ **Actions** — Shariah approve, pay the supplier, confirm delivery, pay
  installments (auto-approve), settle early with rebate, mark default, recover
- ✨ Desert sand & cobalt "trade desk" light theme, layout #13
- ⚠️ Decoded errors (`InvalidMarkup`, `InvalidState`, `NotBuyer`,
  `NoInstallmentsDue`, `ProtocolPaused`, …)

## Deploy

```bash
cd 17-murabaha-finance
export DEPLOYER_PRIVATE_KEY=0x…
forge script script/Deploy.s.sol --rpc-url https://ethereum-sepolia-rpc.publicnode.com --broadcast
```

## Hosting (s0sta.com/murabaha)

1. hPanel → **Files → File Manager** → `public_html/murabaha`
2. Upload the **contents of `frontend/`** into it
3. Pre-filled configs: `js/config.js` + `api/config.php`
4. Verify: `https://s0sta.com/murabaha/api/health.php`

## Self-test

```bash
anvil
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
cd frontend/smoke && node smoke.js
```
