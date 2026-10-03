# Senate DAO dApp — Frontend for dao.s0sta.com

A modern, self-contained web3 dashboard for the from-scratch Governor (Project 09).
**No build step, no Node server** — pure HTML/CSS/JS with ethers.js v6 from a CDN,
plus an optional tiny PHP config layer. Uploads directly to any PHP/static hosting.

Live: **https://dao.s0sta.com**

> ✅ **Already deployed on Sepolia** — the config files below are pre-filled.
> Just upload this folder to Hostinger and the site is live.

---

## Features

- 🔌 **Wallet connect** (MetaMask / any EIP-1193 wallet), auto-reconnect, network badge & switching
- 🗳 **Voting power** — your GOV balance (snapshotted at proposal creation), threshold readout
- 📜 **Proposal ballots** — left feed with status seals (Active / Succeeded / Defeated / Executed / Canceled),
  for/against vote bars, quorum check, live countdown, proposer & snapshot block
  (descriptions are recovered from the propose transactions' calldata — no off-chain server needed)
- 👍 **Vote / Execute / Cancel** inline on each ballot, with a "VOTED" stamp after you vote
- 🏛 **Create proposals** — target + ETH value + calldata + description (threshold enforced on-chain)
- 📊 **Governance card** — voting period, quorum, proposal count, treasury ETH
- 📜 **Activity feed** — ProposalCreated / VoteCast / ProposalExecuted / ProposalCanceled
- ⚠️ **Human-readable errors** — `BelowProposalThreshold()`, `AlreadyVoted()`, `VotingEnded()`, `ProposalNotSucceeded()` decoded
- ✨ **Parchment & ink theme** (the portfolio's first light theme): cream paper, crimson seals,
  gold accents, Playfair Display headings — static background, motion on elements only
- 🍞 Toasts, read-only mode without a wallet, responsive layout

## File structure

```
frontend/
├── index.html          # the whole page
├── css/style.css       # parchment & ink theme, senate layout
├── js/abi.js           # Governor + GovToken ABIs (auto-generated from forge build)
├── js/config.js        # governor address + network config
├── js/app.js           # all dApp logic
├── smoke/smoke.js      # end-to-end self-test (Node, no npm)
└── api/
    ├── config.php      # OPTIONAL server-side config (sets governor address on Hostinger)
    └── health.php      # health check endpoint
```

### Self-test the frontend against your deployment

```bash
anvil                                                        # terminal 1
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast   # terminal 2
cd frontend && GOVERNOR=0x… node smoke/smoke.js   # propose/vote/execute/cancel flow (own test governor)
```

---

## 1. Deploy the governor (Sepolia testnet)

```bash
cd 09-dao-governance        # from the repo root

export DEPLOYER_PRIVATE_KEY=0x…
export SEPOLIA_RPC=https://ethereum-sepolia-rpc.publicnode.com

forge script script/Deploy.s.sol \
  --rpc-url $SEPOLIA_RPC \
  --broadcast \
  -vvvv
```

The script deploys GOV (1,000,000 supply to the deployer) and the Governor:
3-day voting, 10,000 GOV proposal threshold, 4% quorum.

### Local demo (no testnet ETH needed)

```bash
anvil                                                       # terminal 1
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

Then open the dApp → Settings → Network: Local (Anvil) → paste the governor address.

## 2. Configure the dApp

| Where | What |
|---|---|
| `js/config.js` | set `governorAddress` and `defaultChainId` (ships in the repo) |
| `api/config.php` | set `governorAddress` — takes priority when hosted on PHP |
| Browser UI | Settings ⚙ saves the address in localStorage |

## 3. Upload to Hostinger (subdomain dao.s0sta.com)

1. hPanel → **Domains → Subdomains**, create `dao` pointing at your domain.
2. Upload the **contents of `frontend/`** into the subdomain's document root.
3. Edit `api/config.php` (or `js/config.js` before uploading) and paste the governor address.
4. Open `https://dao.s0sta.com` — done. Verify PHP via `https://dao.s0sta.com/api/health.php`.

## 4. Reference the live site from GitHub

> Live demo: https://dao.s0sta.com · Sepolia testnet · governor in `src/`

## Rebranding

- Colors: CSS variables at the top of `css/style.css` (`--bg` parchment, `--accent-1` crimson, `--accent-2` gold)
- Motion: tweak `sealIn`, `ballotIn`, `sealPulse`, `stampIn` keyframes
- Links: `js/config.js` + `api/config.php`

## Troubleshooting

| Problem | Fix |
|---|---|
| "No wallet detected" | Install MetaMask; site must be on https or localhost |
| "Could not read the governor" | Address/network mismatch — check Settings (the app also retries a backup RPC) |
| Vote buttons missing | Only active proposals accept votes, and only if you haven't voted yet |
| Propose reverts | You need ≥ 10,000 GOV — transfer GOV to yourself from the deployer |
