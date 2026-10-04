# Tamweel dApp — Frontend for s0sta.com/tamweel

The hosted banking hall for the credit protocol (Project 20): deposit, borrow
against collateral, request installment loans and vote on bank parameters.
No build step — pure HTML/CSS/JS with ethers v6 UMD.

Live: **https://s0sta.com/tamweel**

## Features

- 🔌 Wallet connect, network badge, settings, read-only mode
- 🏦 **Bank strip** — total assets, borrowed, live utilization and borrow APR,
  your vault shares
- 💳 **Deposits** — deposit (auto-approve) and withdraw vault shares
- 📈 **Credit** — your collateral, debt, health factor and credit score;
  supply collateral, borrow and repay
- 📜 **Loans & governance** — request installment loans; vote on and execute
  parameter proposals
- ✨ Oxblood & champagne "banking hall" light theme, layout #16
- ⚠️ Decoded errors (`Unhealthy`, `CreditDenied`, `InsufficientLiquidity`,
  `Timelocked`, `InsufficientFund`, …)

## Deploy

```bash
cd 20-tamweel-credit
export DEPLOYER_PRIVATE_KEY=0x…
forge script script/Deploy.s.sol --rpc-url https://ethereum-sepolia-rpc.publicnode.com --broadcast
```

## Hosting (s0sta.com/tamweel)

1. hPanel → **Files → File Manager** → `public_html/tamweel`
2. Upload the **contents of `frontend/`** into it
3. Pre-filled configs: `js/config.js` + `api/config.php`
4. Verify: `https://s0sta.com/tamweel/api/health.php`

## Self-test

```bash
anvil
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
cd frontend/smoke && node smoke.js
```
