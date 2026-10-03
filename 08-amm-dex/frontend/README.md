# AMM DEX dApp — Frontend for dex.s0sta.com

A modern, self-contained web3 dashboard for the from-scratch AMM (Project 08).
**No build step, no Node server** — pure HTML/CSS/JS with ethers.js v6 from a CDN,
plus an optional tiny PHP config layer. Uploads directly to any PHP/static hosting.

Live: **https://dex.s0sta.com**

> ✅ **Already deployed on Sepolia** — the config files below are pre-filled.
> Just upload this folder to Hostinger and the site is live.

---

## Features

- 🔌 **Wallet connect** (MetaMask / any EIP-1193 wallet), auto-reconnect, network badge & switching
- 📊 **KPI row** — pool GLD, pool USD, live price, LP supply (values bump on refresh)
- ⇄ **Swap terminal** — Uniswap-style pay/receive fields, rotating direction arrow, MAX button,
  live rate, price impact and min-received (0.5% slippage tolerance), auto-approve
- 💧 **Liquidity** — Add/Remove segmented control, share preview on input, LP balance + MAX,
  receive preview, auto-approve both tokens
- 👛 **My position** — LP balance, pool share %, underlying GLD + USD
- 🧭 **Pool composition gauge** — animated GLD/USD split bar
- 📜 **Pool activity** — compact event list (Swap / Mint / Burn / Sync) from the pair
- ⚠️ **Human-readable errors** — `InsufficientOutputAmount()`, `InsufficientAAmount()`, `K()` decoded
- ✨ Gold & sapphire theme — **static background, motion only on elements** (entrances, arrow
  rotation, gauge width, KPI bumps, CTA glow)
- 🍞 Toasts, read-only mode without a wallet, responsive layout

## File structure

```
frontend/
├── index.html          # the whole page
├── css/style.css       # gold/sapphire workbench theme (no bg animation)
├── js/abi.js           # Router + Pair + Factory + ERC20 ABIs (auto-generated from forge build)
├── js/config.js        # router address + network config
├── js/app.js           # all dApp logic
├── smoke/smoke.js      # end-to-end self-test (Node, no npm)
└── api/
    ├── config.php      # OPTIONAL server-side config (sets router address on Hostinger)
    └── health.php      # health check endpoint
```

### Self-test the frontend against your deployment

```bash
anvil                                                        # terminal 1
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast   # terminal 2
cd frontend && ROUTER=0x… node smoke/smoke.js   # swap both ways / liquidity add-remove / errors / events
```

---

## 1. Deploy the AMM (Sepolia testnet)

```bash
cd 08-amm-dex                # from the repo root

export DEPLOYER_PRIVATE_KEY=0x…
export SEPOLIA_RPC=https://ethereum-sepolia-rpc.publicnode.com

forge script script/Deploy.s.sol \
  --rpc-url $SEPOLIA_RPC \
  --broadcast \
  -vvvv
```

The script deploys the factory, the router, GLD and USD tokens, and seeds the pool
with 1,000,000 GLD / 2,000,000 USD (1 GLD = 2 USD).

### Local demo (no testnet ETH needed)

```bash
anvil                                                       # terminal 1
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

Then open the dApp → Settings → Network: Local (Anvil) → paste the router address.

## 2. Configure the dApp

| Where | What |
|---|---|
| `js/config.js` | set `routerAddress` (+ optional `tokenA`/`tokenB`) and `defaultChainId` |
| `api/config.php` | set `routerAddress` — takes priority when hosted on PHP |
| Browser UI | Settings ⚙ saves the address in localStorage |

The app auto-discovers the pair: `factory.getPair(tokenA, tokenB)` from the config,
falling back to `factory.allPairs(0)`.

## 3. Upload to Hostinger (subdomain dex.s0sta.com)

1. hPanel → **Domains → Subdomains**, create `dex` pointing at your domain.
2. Upload the **contents of `frontend/`** into the subdomain's document root.
3. Edit `api/config.php` (or `js/config.js` before uploading) and paste the router address.
4. Open `https://dex.s0sta.com` — done. Verify PHP via `https://dex.s0sta.com/api/health.php`.

## 4. Reference the live site from GitHub

> Live demo: https://dex.s0sta.com · Sepolia testnet · AMM in `src/`

## Rebranding

- Colors: CSS variables at the top of `css/style.css` (`--accent-1` gold, `--accent-2` sapphire)
- Motion: element-only — tweak `cardIn`, `kpiIn`, `numBump`, `ctaGlow`, `.dir-btn.flipped`
- Links: `js/config.js` + `api/config.php`

## Troubleshooting

| Problem | Fix |
|---|---|
| "No wallet detected" | Install MetaMask; site must be on https or localhost |
| "Could not read the pool" | Router address/network mismatch — check Settings |
| Swap reverts | The app auto-approves first; ensure you hold the input token and ETH for gas |
| Liquidity preview missing | Enter both amounts — the share preview needs the pair reserves |
