# Sahm dApp — Frontend for s0sta.com/sahm

The hosted trading terminal for the exchange (Project 21): order book trading,
AMM swaps, margin deposits and leveraged longs, plus LP governance. No build
step — pure HTML/CSS/JS with ethers v6 UMD.

Live: **https://s0sta.com/sahm**

## Features

- 🔌 Wallet connect, network badge, settings, read-only mode
- 📟 **Ticker tape** — oracle price, volume, AMM price, fees, circuit-breaker state
- 📖 **Order book** — open bids/asks with fill/cancel; place bids and asks
- 💱 **Swap & margin** — deposit margin, swap quote→token, open leveraged longs
- ⚖ **Governance** — vote/execute proposals; add AMM liquidity
- ✨ Shadow blue & citron "trading terminal" dark theme, layout #17
- ⚠️ Decoded errors (`LeverageLimit`, `InsufficientOutput`, `OrderInactive`,
  `CircuitBrokenError`, `Timelocked`, …)

## Deploy

```bash
cd 21-sahm-exchange
export DEPLOYER_PRIVATE_KEY=0x…
forge script script/Deploy.s.sol --rpc-url https://ethereum-sepolia-rpc.publicnode.com --broadcast
```

## Hosting (s0sta.com/sahm)

1. hPanel → **Files → File Manager** → `public_html/sahm`
2. Upload the **contents of `frontend/`** into it
3. Pre-filled configs: `js/config.js` + `api/config.php`
4. Verify: `https://s0sta.com/sahm/api/health.php`

## Self-test

```bash
anvil
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
cd frontend/smoke && node smoke.js
```
