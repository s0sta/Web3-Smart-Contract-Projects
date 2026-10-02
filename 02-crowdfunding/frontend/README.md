# CrowdFund dApp — Frontend for crowdfund.s0sta.com

A modern, self-contained web3 dashboard for the CrowdFund protocol (Project 02).
**No build step, no Node server** — pure HTML/CSS/JS with ethers.js v6 from a CDN,
plus an optional tiny PHP config layer. Uploads directly to any PHP/static hosting.

Live: **https://crowdfund.s0sta.com**

> ✅ **Already deployed on Sepolia** (factory + example campaign) — the config files
> below are pre-filled. Just upload this folder to Hostinger and the site is live.

---

## Features

- 🔌 **Wallet connect** (MetaMask / any EIP-1193 wallet), auto-reconnect, network badge & switching
- 🚀 **Launch campaigns** — set a goal (ETH) and duration (days); anyone can create
- 📈 **Campaign cards** — animated progress bars with shimmer, live deadline countdowns, status pills (Active / Successful / Failed), creator + your pledge
- 💸 **Pledge ETH**, **claim** as creator on success, **pull refunds** as backer on failure — exactly the protocol's flow
- 👑 **Platform controls** (factory owner only): update the platform fee, withdraw accrued fees
- 📜 **Live activity feed** — CampaignCreated / Pledged / Claimed / Refunded / fee events with explorer links
- ⚠️ **Human-readable errors** — Solidity custom errors decoded (`NotSuccessful()`, `CreatorCannotPledge()`, `NothingToRefund()`…)
- ✨ Emerald & amber theme with rising-coin particles, shimmer bars, staggered card entrances, spinning coin logo
- 🍞 Toasts, copy-to-clipboard, read-only mode without a wallet, responsive layout

## File structure

```
frontend/
├── index.html          # the whole page
├── css/style.css       # emerald/amber funding theme + motion language
├── js/abi.js           # factory + campaign ABIs (auto-generated from forge build)
├── js/config.js        # factory address + network config
├── js/app.js           # all dApp logic
├── smoke/smoke.js      # end-to-end self-test (Node, no npm)
└── api/
    ├── config.php      # OPTIONAL server-side config (sets factory address on Hostinger)
    └── health.php      # health check endpoint
```

### Self-test the frontend against your deployment

```bash
anvil                                                        # terminal 1
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast   # terminal 2
cd frontend && FACTORY=0x… node smoke/smoke.js    # pledge/claim/refund lifecycle, errors, events
```

---

## 1. Deploy the factory (Sepolia testnet)

```bash
cd 02-crowdfunding          # from the repo root

export DEPLOYER_PRIVATE_KEY=0x…
export SEPOLIA_RPC=https://ethereum-sepolia-rpc.publicnode.com

forge script script/Deploy.s.sol \
  --rpc-url $SEPOLIA_RPC \
  --broadcast \
  -vvvv
```

Copy the logged `Factory : 0x…` address. The script also creates one example campaign
(10 ETH goal, 30 days).

### Local demo (no testnet ETH needed)

```bash
anvil                                                       # terminal 1
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

Then open the dApp → Settings → Network: Local (Anvil) → paste the factory address.

## 2. Configure the dApp

| Where | What |
|---|---|
| `js/config.js` | set `factoryAddress` and `defaultChainId` (ships in the repo) |
| `api/config.php` | set `factoryAddress` — takes priority when hosted on PHP |
| Browser UI | Settings ⚙ saves the address in localStorage |

## 3. Upload to Hostinger (subdomain crowdfund.s0sta.com)

1. hPanel → **Domains → Subdomains**, create `crowdfund` pointing at your domain.
2. Upload the **contents of `frontend/`** into the subdomain's document root.
3. Edit `api/config.php` (or `js/config.js` before uploading) and paste the factory address.
4. Open `https://crowdfund.s0sta.com` — done. Verify PHP via `https://crowdfund.s0sta.com/api/health.php`.

## 4. Reference the live site from GitHub

The project README (`../README.md`) links the live demo. On GitHub:

> Live demo: https://crowdfund.s0sta.com · Sepolia testnet · factory + campaign in `src/`

## Rebranding

- Colors: CSS variables at the top of `css/style.css` (`--accent-1` emerald, `--accent-2` amber)
- Motion: tweak `coinRise` / `shimmer` / `cardIn` keyframes
- Links: `js/config.js` + `api/config.php`

## Troubleshooting

| Problem | Fix |
|---|---|
| "No wallet detected" | Install MetaMask; site must be on https or localhost |
| "Could not read the factory" | Address/network mismatch — check Settings |
| Wrong network | The site prompts to switch on connect; or Settings → network |
| Events empty | New deployments show nothing until the first transaction |
