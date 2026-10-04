# Zakat Engine dApp — Frontend for s0sta.com/zakat

The hosted "eight gates" dashboard for the zakat engine (Project 18): declare
wealth, watch the nisab & hawl clock, pay the 2.5%, and see the ring-fenced
fund flow only to the eight asnaf via the 2-of-3 committee.
No build step — pure HTML/CSS/JS with ethers v6 UMD.

Live: **https://s0sta.com/zakat**

## Features

- 🔌 Wallet connect, network badge, settings, read-only mode
- 🌙 **Fund strip** — ring-fenced fund, collected, distributed, nisab, status
- 🕋 **The eight gates** — Quran 9:60 asnaf cards with allocation bars
- 🧮 **Your zakat** — declared wealth, hawl clock, 2.5% due, lifetime paid;
  declare wealth and pay (auto-approve)
- 🤲 **Disbursements** — committee proposals with 2-of-3 approval counts;
  committee members vote inline
- ⚖ **Committee** — register KYC'd recipients under an asnaf with a proof hash;
  propose disbursements
- ✨ Saffron & indigo "eight gates" light theme, layout #14
- ⚠️ Decoded errors (`BelowNisab`, `NothingDue`, `InsufficientZakatFund`,
  `AlreadyVoted`, `RecipientNotActive`, …)

## Deploy

```bash
cd 18-zakat-engine
export DEPLOYER_PRIVATE_KEY=0x…
forge script script/Deploy.s.sol --rpc-url https://ethereum-sepolia-rpc.publicnode.com --broadcast
```

## Hosting (s0sta.com/zakat)

1. hPanel → **Files → File Manager** → `public_html/zakat`
2. Upload the **contents of `frontend/`** into it
3. Pre-filled configs: `js/config.js` + `api/config.php`
4. Verify: `https://s0sta.com/zakat/api/health.php`

## Self-test

```bash
anvil
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
cd frontend/smoke && node smoke.js
```
