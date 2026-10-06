# Ataa dApp — Frontend for s0sta.com/ataa

The hosted giving hub (Project 26): a zakat calculator wizard across seven
asset classes, sadaqa donations, donor tracking ("where my money went"),
monthly sponsorships and governance. No build step — pure HTML/CSS/JS with
ethers v6 UMD.

Live: **https://s0sta.com/ataa**

## Features

- 🔌 Wallet connect, network badge, settings, read-only mode
- 🤲 **My giving strip** — total given, allocated, unallocated, pool, beneficiaries
- 🧮 **Zakat calculator** — declare wealth per asset class, see nisab and your
  live due (2.5% / 5% / 10% / 20%), pay in one click
- 💝 **Give sadaqa** — donate any amount; browse verified beneficiaries; start
  monthly sponsorships
- 🔎 **Where my money went** — every contribution traced to the disbursements
  it funded
- ⚖ Governance proposals (vote/execute)
- ✨ Mercy emerald & warm sand "giving hub" light theme, layout #22
- ⚠️ Decoded errors (`BelowNisab`, `HawlNotComplete`, `ExceedsDue`,
  `InsufficientPool`, `NotDue`, `Timelocked`, …)

## Deploy

```bash
cd 26-ataa-giving
export DEPLOYER_PRIVATE_KEY=0x…
forge script script/Deploy.s.sol --rpc-url https://ethereum-sepolia-rpc.publicnode.com --broadcast
```

## Hosting (s0sta.com/ataa)

1. hPanel → **Files → File Manager** → `public_html/ataa`
2. Upload the **contents of `frontend/`** into it
3. Pre-filled configs: `js/config.js` + `api/config.php`
4. Verify: `https://s0sta.com/ataa/api/health.php`

## Self-test

```bash
anvil
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
cd frontend/smoke && node smoke.js
```
