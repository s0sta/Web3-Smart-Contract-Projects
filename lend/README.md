# LendVault dApp — Frontend for s0sta.com/lend

A modern, self-contained web3 dashboard for the from-scratch lending protocol (Project 10).
**No build step, no Node server** — pure HTML/CSS/JS with ethers.js v6 from a CDN,
plus an optional tiny PHP config layer. Uploads directly to any PHP/static hosting.

Live: **https://s0sta.com/lend**

> ✅ **Already deployed on Sepolia** — the config files below are pre-filled.
> Just upload this folder to Hostinger and the site is live.

---

## Features

- 🔌 **Wallet connect** (MetaMask / any EIP-1193 wallet), auto-reconnect, network badge & switching
- 📊 **Utilization band** — supplied, borrowed, utilization bar, APR and fixed collateral price
- ⬇️ **Supply panel** — deposit ETH as collateral, withdraw while your position stays healthy
- 🩺 **Position panel** — a **health-factor arc gauge** (red → amber → green zones), supplied,
  live-interest debt (ticks every second), borrow limit, available credit, net value, and an
  LTV borrow-limit meter with the 66% marker
- ⬆️ **Borrow / Repay panel** — borrow stable against collateral, repay (auto-approve),
  and a collapsible liquidation tool (repay up to 50% of an unhealthy position, seize at a 10% bonus)
- 🚨 **Emergency brake** — a pause banner appears when the owner pauses the vault (new deposits
  and borrows blocked; withdrawals, repayments and liquidations always stay open), plus the owner toggle
- 📜 **Activity feed** — Deposited / Withdrawn / Borrowed / Repaid / Liquidated / Paused / Unpaused
- ⚠️ **Human-readable errors** — `BorrowLimitExceeded()`, `RepayExceedsDebt()`, `NotLiquidatable()`, `VaultPaused()` decoded
- ✨ Crimson & ice "risk & collateral" theme (crimson as a first-time primary) — static background,
  motion on elements only (health arc fill, utilization shimmer, limit meter, number bumps)
- 🍞 Toasts, read-only mode without a wallet, responsive layout

## File structure

```
frontend/
├── index.html          # the whole page
├── css/style.css       # crimson/ice vault-counter theme
├── js/abi.js           # LendVault + stable ABIs (auto-generated from forge build)
├── js/config.js        # vault address + network config
├── js/app.js           # all dApp logic
├── smoke/smoke.js      # end-to-end self-test (Node, no npm)
└── api/
    ├── config.php      # OPTIONAL server-side config (sets vault address on Hostinger)
    └── health.php      # health check endpoint
```

### Self-test the frontend against your deployment

```bash
anvil                                                        # terminal 1
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast   # terminal 2
cd frontend && VAULT=0x… node smoke/smoke.js   # deposit/borrow/repay/withdraw/liquidate/pause
```

---

## 1. Deploy the vault (Sepolia testnet)

```bash
cd 10-lending-protocol      # from the repo root

export DEPLOYER_PRIVATE_KEY=0x…
export SEPOLIA_RPC=https://ethereum-sepolia-rpc.publicnode.com

forge script script/Deploy.s.sol \
  --rpc-url $SEPOLIA_RPC \
  --broadcast \
  -vvvv
```

The script deploys the stablecoin (USDx) and the vault, wiring the vault as the sole minter/burner.
Parameters: 66% LTV, 80% liquidation threshold, 10% bonus, 50% close factor, 10% APR, $2,000/ETH fixed price.

### Local demo (no testnet ETH needed)

```bash
anvil                                                       # terminal 1
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

Then open the dApp → Settings → Network: Local (Anvil) → paste the vault address.

## 2. Configure the dApp

| Where | What |
|---|---|
| `js/config.js` | set `vaultAddress` and `defaultChainId` (ships in the repo) |
| `api/config.php` | set `vaultAddress` — takes priority when hosted on PHP |
| Browser UI | Settings ⚙ saves the address in localStorage |

## 3. Upload to Hostinger (path s0sta.com/lend)

1. hPanel → **Files → File Manager**, open your main domain's `public_html`.
2. Create the folder `lend` and upload the **contents of `frontend/`** into it.
3. Edit `api/config.php` (or `js/config.js` before uploading) and paste the vault address.
4. Open `https://s0sta.com/lend` — done. Verify PHP via `https://s0sta.com/lend/api/health.php`.

## 4. Reference the live site from GitHub

> Live demo: https://s0sta.com/lend · Sepolia testnet · vault in `src/`

## Rebranding

- Colors: CSS variables at the top of `css/style.css` (`--accent-1` crimson, `--accent-2` ice)
- Motion: tweak `numBump`, `hfBump`, `fillShine` keyframes and the arc/limit transitions
- Links: `js/config.js` + `api/config.php`

## Troubleshooting

| Problem | Fix |
|---|---|
| "No wallet detected" | Install MetaMask; site must be on https or localhost |
| "Could not read the vault" | Address/network mismatch — check Settings (the app also retries a backup RPC) |
| Borrow reverts | You need collateral first; the limit is 66% of your collateral value |
| Withdraw reverts | Remaining collateral would no longer cover your debt at LTV — repay first |
| Pause banner shown | The owner paused the vault — you can still withdraw, repay and liquidate |
