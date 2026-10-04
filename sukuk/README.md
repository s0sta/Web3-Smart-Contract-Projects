# Sukuk Vault dApp — Frontend for s0sta.com/sukuk

The hosted certificate gallery for the ijarah sukuk vault (Project 15): certificates
backed by a leased asset, Shariah-approved profit epochs and maturity redemption.
No build step — pure HTML/CSS/JS with ethers v6 UMD.

Live: **https://s0sta.com/sukuk**

## Features

- 🔌 Wallet connect, network badge, settings, read-only mode
- 🏷 **The certificate** — series name, underlying asset, face value, certificates
  issued, indicative profit rate, maturity date and live status (OPEN / MATURED /
  REDEEMING / FROZEN)
- 💚 **Profit distributions** — pending Shariah approval, distributable pool, profit
  reserve ratio, epoch count, your claimable profit; distribute + claim
- 📜 **Invest & redeem** — your certificates and redeemed principal, purchase at face
  value (auto-approve), redeem at maturity
- 🕌 **Issuer & Shariah** — record ijarah income, approve income (Shariah), sell the
  underlying asset into the redemption pool at maturity
- ✨ Plum & mint "certificate gallery" dark theme, layout #11
- ⚠️ Decoded errors (`ExceedsSupply`, `NotMatured`, `RedemptionUnavailable`,
  `NothingToClaim`, `FrozenSeries`, …)

## Deploy

```bash
cd 15-sukuk-vault
export DEPLOYER_PRIVATE_KEY=0x…
forge script script/Deploy.s.sol --rpc-url https://ethereum-sepolia-rpc.publicnode.com --broadcast
```

## Hosting (s0sta.com/sukuk)

1. hPanel → **Files → File Manager** → `public_html/sukuk`
2. Upload the **contents of `frontend/`** into it
3. Pre-filled configs: `js/config.js` + `api/config.php`
4. Verify: `https://s0sta.com/sukuk/api/health.php`

## Self-test

```bash
anvil
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
cd frontend/smoke && node smoke.js
```
