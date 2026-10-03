# TokenVesting dApp — Frontend for vesting.s0sta.com

A modern, self-contained web3 dashboard for the TokenVesting protocol (Project 07).
**No build step, no Node server** — pure HTML/CSS/JS with ethers.js v6 from a CDN,
plus an optional tiny PHP config layer. Uploads directly to any PHP/static hosting.

Live: **https://vesting.s0sta.com**

> ✅ **Already deployed on Sepolia** — the config files below are pre-filled.
> Just upload this folder to Hostinger and the site is live.

---

## Features

- 🔌 **Wallet connect** (MetaMask / any EIP-1193 wallet), auto-reconnect, network badge & switching
- ⭕ **Vesting donut** — a centered ring filling with your vested % + a live countdown inside
  (starts in / cliff in / fully vested in), with a glowing progress marker
- 🏷 **Info chips** — start, cliff, end, total, claimed, status (not started / in cliff / active / revoked / finished)
- 💰 **Releasable stage** — the exact claimable amount ticking up every second, with one-click Claim
- 📊 **Schedule bar** — a timeline from start → cliff → end with a pulsing "now" marker and the vested fill
- 👑 **Owner tools** — fund a schedule (auto-approve included) and revoke one (unvested returns to you)
- 🎞 **Activity strip** — horizontally scrollable event cards (ScheduleCreated / Claimed / ScheduleRevoked)
- ⚠️ **Human-readable errors** — `NothingToClaim()`, `NoSchedule()`, `ScheduleExists()`, `AlreadyRevoked()` decoded
- ✨ Slate & rose "time-release" theme: falling hourglass sands, breathing mark, springy chips
- 🍞 Toasts, copy-to-clipboard, read-only mode without a wallet, responsive layout

## File structure

```
frontend/
├── index.html          # the whole page
├── css/style.css       # slate/rose time-release theme + motion language
├── js/abi.js           # TokenVesting + IERC20 ABIs (auto-generated from forge build)
├── js/config.js        # vesting address + network config
├── js/app.js           # all dApp logic
├── smoke/smoke.js      # end-to-end self-test (Node, no npm)
└── api/
    ├── config.php      # OPTIONAL server-side config (sets vesting address on Hostinger)
    └── health.php      # health check endpoint
```

### Self-test the frontend against your deployment

```bash
anvil                                                        # terminal 1
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast   # terminal 2
cd frontend && VESTING=0x… node smoke/smoke.js   # cliff/claim/revoke/time-travel/errors/events
```

---

## 1. Deploy the vesting contract (Sepolia testnet)

```bash
cd 07-token-vesting         # from the repo root

export DEPLOYER_PRIVATE_KEY=0x…
export BENEFICIARY=0x…      # who receives the example 1,000,000 VEST schedule
export SEPOLIA_RPC=https://ethereum-sepolia-rpc.publicnode.com

forge script script/Deploy.s.sol \
  --rpc-url $SEPOLIA_RPC \
  --broadcast \
  -vvvv
```

The script deploys VEST + the vesting contract and funds one schedule: 1,000,000 VEST with a 1-year cliff, then 3 years linear.

### Local demo (no testnet ETH needed)

```bash
anvil                                                       # terminal 1
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

Then open the dApp → Settings → Network: Local (Anvil) → paste the vesting address.

## 2. Configure the dApp

| Where | What |
|---|---|
| `js/config.js` | set `vestingAddress` and `defaultChainId` (ships in the repo) |
| `api/config.php` | set `vestingAddress` — takes priority when hosted on PHP |
| Browser UI | Settings ⚙ saves the address in localStorage |

## 3. Upload to Hostinger (subdomain vesting.s0sta.com)

1. hPanel → **Domains → Subdomains**, create `vesting` pointing at your domain.
2. Upload the **contents of `frontend/`** into the subdomain's document root.
3. Edit `api/config.php` (or `js/config.js` before uploading) and paste the vesting address.
4. Open `https://vesting.s0sta.com` — done. Verify PHP via `https://vesting.s0sta.com/api/health.php`.

## 4. Reference the live site from GitHub

> Live demo: https://vesting.s0sta.com · Sepolia testnet · vesting in `src/`

## Rebranding

- Colors: CSS variables at the top of `css/style.css` (`--accent-1` rose, `--accent-2` ice)
- Motion: tweak `sandFall`, `markBreathe`, `chipIn`, `markerPulse` keyframes
- Links: `js/config.js` + `api/config.php`

## Troubleshooting

| Problem | Fix |
|---|---|
| "No wallet detected" | Install MetaMask; site must be on https or localhost |
| "Could not read the contract" | Address/network mismatch — check Settings |
| Ring stuck at 0% | Your wallet may have no schedule, or you're still before the cliff — the countdown shows which |
| Create schedule reverts | The form auto-approves first; make sure your wallet holds enough VEST |
