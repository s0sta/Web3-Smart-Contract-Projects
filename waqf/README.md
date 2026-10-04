# Waqf Endowment dApp — Frontend for s0sta.com/waqf

The hosted dashboard for the waqf protocol (Project 13): a Sharia-compliant endowment —
irrevocable corpus, income-only distributions, beneficiary register, donor-weighted
governance. No build step — pure HTML/CSS/JS with ethers v6 UMD.

Live: **https://s0sta.com/waqf**

## Features

- 🔌 Wallet connect, network badge, settings, read-only mode
- 🕌 **Vault strip** — corpus (irrevocable), income pool, distributed-to-date,
  operational fund, live/frozen status
- 🕊 **Beneficiaries** — register with weight bars, add new causes (nazir)
- ⚖ **Governance** — proposals with lifecycle seals (Confirmation / Voting / Timelock /
  Succeeded / Executed / Defeated / Canceled), nazir confirmations, donor votes,
  execute/cancel; propose form for all five types
- 🤲 **The Waqf** — your contribution and voting power, endow (irrevocable),
  record income (nazir), distribute to beneficiaries
- ✨ Emerald & ivory with gold accents — "waqf serenity" light theme, layout #9
- ⚠️ Decoded errors (`BelowProposalThreshold`, `Timelocked`, `DistributionsFrozen`, …)

## Deploy

```bash
cd 13-waqf-endowment
export DEPLOYER_PRIVATE_KEY=0x…
forge script script/Deploy.s.sol --rpc-url https://ethereum-sepolia-rpc.publicnode.com --broadcast
```

## Hosting (s0sta.com/waqf)

1. hPanel → **Files → File Manager** → `public_html/waqf`
2. Upload the **contents of `frontend/`** into it
3. Pre-filled configs: `js/config.js` + `api/config.php`
4. Verify: `https://s0sta.com/waqf/api/health.php`

## Self-test

```bash
anvil
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
cd frontend/smoke && node smoke.js
```
