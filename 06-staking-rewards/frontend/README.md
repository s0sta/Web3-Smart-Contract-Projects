# StakeVault dApp — Frontend for stake.s0sta.com

A modern, self-contained web3 dashboard for the StakeVault protocol (Project 06).
**No build step, no Node server** — pure HTML/CSS/JS with ethers.js v6 from a CDN,
plus an optional tiny PHP config layer. Uploads directly to any PHP/static hosting.

Live: **https://stake.s0sta.com**

> ✅ **Already deployed on Sepolia** — the config files below are pre-filled.
> Just upload this folder to Hostinger and the site is live.

---

## Features

- 🔌 **Wallet connect** (MetaMask / any EIP-1193 wallet), auto-reconnect, network badge & switching
- ⏱ **Live reward ticker** — "your earned" advances every second at the exact on-chain rate
  (re-synced with the contract every 10s), with a pulsing claim button
- 🌱 **Stake** with allowance detection + one-click "Approve max"
- 💧 **Withdraw** · 🏆 **Claim** · 🚪 **Exit all** · ⚠️ **Emergency withdraw** (confirm dialog — rewards forfeited)
- 📊 **Vault stats** — total staked, reward rate (per day), period-end countdown, your stake
- 👑 **Owner panel** — fund emissions (amount + duration), recover stray ERC-20s (STAKE/REWARD protected)
- 📜 **Live activity feed** — Staked / Withdrawn / RewardPaid / RewardsNotified / EmergencyWithdrawn / Recovered
- ⚠️ **Human-readable errors** — `InsufficientStake()`, `ProtectedToken()`, `ZeroAmount()` decoded
- ✨ Teal & gold "yield harvest" theme: swaying yield sparks, rotating sunburst logo, claim-glow pulse
- 🍞 Toasts, copy-to-clipboard, read-only mode without a wallet, responsive layout

## File structure

```
frontend/
├── index.html          # the whole page
├── css/style.css       # teal/gold yield theme + motion language
├── js/abi.js           # StakeVault + IERC20 ABIs (auto-generated from forge build)
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
cd frontend && VAULT=0x… node smoke/smoke.js   # stake/earn/claim/withdraw/emergency/rollover/guards/events
```

---

## 1. Deploy the vault (Sepolia testnet)

```bash
cd 06-staking-rewards        # from the repo root

export DEPLOYER_PRIVATE_KEY=0x…
export SEPOLIA_RPC=https://ethereum-sepolia-rpc.publicnode.com

forge script script/Deploy.s.sol \
  --rpc-url $SEPOLIA_RPC \
  --broadcast \
  -vvvv
```

The script deploys STAKE + REWARD demo tokens and the vault, funding 1,000,000 REW over 30 days.

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

## 3. Upload to Hostinger (subdomain stake.s0sta.com)

1. hPanel → **Domains → Subdomains**, create `stake` pointing at your domain.
2. Upload the **contents of `frontend/`** into the subdomain's document root.
3. Edit `api/config.php` (or `js/config.js` before uploading) and paste the vault address.
4. Open `https://stake.s0sta.com` — done. Verify PHP via `https://stake.s0sta.com/api/health.php`.

## 4. Reference the live site from GitHub

> Live demo: https://stake.s0sta.com · Sepolia testnet · vault in `src/`

## Rebranding

- Colors: CSS variables at the top of `css/style.css` (`--accent-1` teal, `--accent-2` gold)
- Motion: tweak `yieldRise`, `rays`, `claimPulse` keyframes
- Links: `js/config.js` + `api/config.php`

## Troubleshooting

| Problem | Fix |
|---|---|
| "No wallet detected" | Install MetaMask; site must be on https or localhost |
| "Could not read the vault" | Address/network mismatch — check Settings |
| Stake reverts | Approve first — the allowance row appears once connected |
| Ticker frozen | It re-syncs on-chain every 10s; make sure the emission period hasn't ended |
