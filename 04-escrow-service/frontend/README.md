# TrustEscrow dApp — Frontend for escrow.s0sta.com

A modern, self-contained web3 dashboard for the TrustEscrow protocol (Project 04).
**No build step, no Node server** — pure HTML/CSS/JS with ethers.js v6 from a CDN,
plus an optional tiny PHP config layer. Uploads directly to any PHP/static hosting.

Live: **https://escrow.s0sta.com**

> ✅ **Already deployed on Sepolia** — the config files below are pre-filled.
> Just upload this folder to Hostinger and the site is live.

---

## Features

- 🔌 **Wallet connect** (MetaMask / any EIP-1193 wallet), auto-reconnect, network badge & switching
- 📜 **Open deals** — lock ETH for a seller, name a neutral arbiter (all parties distinct)
- 🤝 **Deal cards with role-based actions** — seller releases, buyer refunds, either raises a dispute, the arbiter resolves with any split
- 🧭 **Lifecycle timelines** — animated state dots: open → released / refunded / disputed → resolved
- 🏷 **Frozen-fee display** — every deal shows the platform fee it locked at open time
- ✉ **Stamp-on-resolution** — released/refunded/resolved deals get an animated stamp
- 👑 **Platform controls** (escrow owner only): update the fee, withdraw accrued fees
- 📜 **Live activity feed** — DealOpened / Released / Refunded / DisputeRaised / DisputeResolved / fees
- ⚠️ **Human-readable errors** — `NotSeller()`, `NotActive()`, `InvalidSplit()` decoded
- ✨ Fuchsia & orange "deal & seal" theme: converging agreement sparks, seal pulse on the logo, stamp animation
- 🍞 Toasts, copy-to-clipboard, read-only mode without a wallet, responsive layout

## File structure

```
frontend/
├── index.html          # the whole page
├── css/style.css       # fuchsia/orange deal theme + motion language
├── js/abi.js           # TrustEscrow ABI (auto-generated from forge build)
├── js/config.js        # escrow address + network config
├── js/app.js           # all dApp logic
├── smoke/smoke.js      # end-to-end self-test (Node, no npm)
└── api/
    ├── config.php      # OPTIONAL server-side config (sets escrow address on Hostinger)
    └── health.php      # health check endpoint
```

### Self-test the frontend against your deployment

```bash
anvil                                                        # terminal 1
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast   # terminal 2
cd frontend && ESCROW=0x… node smoke/smoke.js   # open/release/refund/dispute+resolve/frozen-fee/errors/events
```

---

## 1. Deploy the escrow (Sepolia testnet)

```bash
cd 04-escrow-service         # from the repo root

export DEPLOYER_PRIVATE_KEY=0x…
export SELLER=0x…            # example-deal seller
export ARBITER=0x…           # example-deal arbiter
export SEPOLIA_RPC=https://ethereum-sepolia-rpc.publicnode.com

forge script script/Deploy.s.sol \
  --rpc-url $SEPOLIA_RPC \
  --broadcast \
  -vvvv
```

The script deploys TrustEscrow with a 0.5% fee and opens one example deal (1 ETH).

### Local demo (no testnet ETH needed)

```bash
anvil                                                       # terminal 1
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

Then open the dApp → Settings → Network: Local (Anvil) → paste the escrow address.

## 2. Configure the dApp

| Where | What |
|---|---|
| `js/config.js` | set `escrowAddress` and `defaultChainId` (ships in the repo) |
| `api/config.php` | set `escrowAddress` — takes priority when hosted on PHP |
| Browser UI | Settings ⚙ saves the address in localStorage |

## 3. Upload to Hostinger (subdomain escrow.s0sta.com)

1. hPanel → **Domains → Subdomains**, create `escrow` pointing at your domain.
2. Upload the **contents of `frontend/`** into the subdomain's document root.
3. Edit `api/config.php` (or `js/config.js` before uploading) and paste the escrow address.
4. Open `https://escrow.s0sta.com` — done. Verify PHP via `https://escrow.s0sta.com/api/health.php`.

## 4. Reference the live site from GitHub

> Live demo: https://escrow.s0sta.com · Sepolia testnet · escrow in `src/`

## Rebranding

- Colors: CSS variables at the top of `css/style.css` (`--accent-1` fuchsia, `--accent-2` orange)
- Motion: tweak `convergeA/B`, `sealPulse`, `stampIn`, `dotPulse` keyframes
- Links: `js/config.js` + `api/config.php`

## Troubleshooting

| Problem | Fix |
|---|---|
| "No wallet detected" | Install MetaMask; site must be on https or localhost |
| "Could not read the escrow" | Address/network mismatch — check Settings |
| Wrong network | The site prompts to switch on connect; or Settings → network |
| Action missing | Actions are role-based — buyer/seller/arbiter each see their own |
