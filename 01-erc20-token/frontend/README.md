# NovaToken dApp — Frontend for erc-20Token.s0sta.com

A modern, self-contained web3 dashboard for the NovaToken ERC-20 contract
(Project 01). **No build step, no Node server** — pure HTML/CSS/JS with
ethers.js v6 loaded from a CDN, plus an optional tiny PHP config layer.
Uploads directly to any PHP/static hosting (Hostinger).

Live: **https://erc-20Token.s0sta.com**

> ✅ **Already deployed on Sepolia**: `0x26b420683E6F6Df39CFceBd7C5bB78B7459b8B62`
> (owner `0x319899FaAAD730519B8a2Bd72d2Eba2370a9B853`) — the config files below are
> pre-filled with this address. Just upload this folder to Hostinger and the site is live.

---

## Features

- 🔌 **Wallet connect** (MetaMask / any EIP-1193 wallet), auto-reconnect, network badge & switching
- 📊 **Live stats** — total supply, max supply, your balance, your permit nonce, owner, pause status (auto-refreshes every 15s)
- ↗ **Transfer**, ✓ **Approve**, ⇄ **TransferFrom**
- 🔥 **Burn** and **Burn From** (allowance-based)
- ✍ **EIP-2612 Permit** — gasless approvals: sign a typed message in your wallet, no approve tx
- 👑 **Owner controls** (only visible to the owner): Mint, Pause/Unpause, two-step ownership transfer, renounce
- 🔍 **Read-only checkers** — anyone's balance, any owner→spender allowance (no wallet needed)
- 📜 **Live activity feed** — recent Transfer/Approval/Mint/Burn/Pause/Ownership events with explorer links
- ⚠️ **Human-readable errors** — Solidity custom errors are decoded (`InsufficientBalance(1000, 5000)` instead of raw hex)
- 🍞 Toast notifications, copy-to-clipboard, responsive dark UI

## File structure

```
frontend/
├── index.html          # the whole page
├── css/style.css       # dark web3 theme (CSS variables for easy rebranding)
├── js/abi.js           # NovaToken ABI (auto-generated from forge build)
├── js/config.js        # token address + network config
├── js/app.js           # all dApp logic
├── smoke/smoke.js      # end-to-end self-test against any deployed token (Node, no npm)
└── api/
    ├── config.php      # OPTIONAL server-side config (sets token address on Hostinger)
    └── health.php      # health check endpoint
```

### Self-test the frontend against your deployment

```bash
anvil                                                   # terminal 1
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast   # terminal 2
cd frontend && TOKEN=0xDEPLOYED_ADDRESS node smoke/smoke.js   # 19 checks: reads, transfer,
                                                              # approve, permit, burn, pause,
                                                              # error decoding, event feed
```

---

## 1. Deploy NovaToken (Sepolia testnet)

```bash
cd 01-erc20-token          # from the repo root

# set your private key + RPC (use a burner key for testnets, never your main key)
export PRIVATE_KEY=0x...
export SEPOLIA_RPC=https://ethereum-sepolia-rpc.publicnode.com

forge script script/Deploy.s.sol \
  --rpc-url $SEPOLIA_RPC \
  --broadcast \
  -vvvv
```

Copy the logged `NovaToken : 0x…` address.

Optional — verify on Etherscan (looks great on a portfolio):

```bash
forge verify-contract <DEPLOYED_ADDRESS> src/Token.sol:NovaToken \
  --rpc-url $SEPOLIA_RPC \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --constructor-args $(cast abi-encode "constructor(string,string,address)" "NovaToken" "NOVA" <YOUR_ADDRESS>)
```

### Local demo (no testnet ETH needed)

```bash
# terminal 1
anvil

# terminal 2
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

Then open the dApp → **Settings → Network: Local (Anvil)** → paste the address.

## 2. Configure the dApp

Pick one:

| Where | What |
|---|---|
| `js/config.js` | set `tokenAddress` and `defaultChainId` (ships in the repo) |
| `api/config.php` | set `tokenAddress` — takes priority when the site is hosted on PHP |
| Browser UI | Settings ⚙ on the site saves the address in localStorage |

## 3. Upload to Hostinger (subdomain erc-20Token.s0sta.com)

1. In hPanel → **Domains → Subdomains**, create `erc-20Token` pointing at your domain.
2. In **Files → File Manager** (or any FTP client), upload the **contents of `frontend/`**
   into the subdomain's document root (`public_html/erc-20Token/` or the folder the
   subdomain points to). Keep the folder structure exactly:
   ```
   index.html
   css/style.css
   js/abi.js  js/config.js  js/app.js
   api/config.php  api/health.php
   ```
3. Edit `api/config.php` on the server (or `js/config.js` before uploading) and paste your
   deployed token address.
4. Open `https://erc-20Token.s0sta.com` — the page works immediately; PHP is only used for
   the config/health endpoints.
5. Verify PHP: `https://erc-20Token.s0sta.com/api/health.php` should return `{"status":"ok",…}`.

## 4. Reference the live site from GitHub

The project README (`../README.md`) already links the live demo. The contract + frontend
live in **[github.com/s0sta/Web3-Smart-Contract-Projects](https://github.com/s0sta/Web3-Smart-Contract-Projects/tree/main/01-erc20-token)**.
On your GitHub profile, pin the repo and mention:

> Live demo: https://erc-20Token.s0sta.com · Sepolia testnet · contracts + tests in `src/`, `test/`

## Rebranding

- Colors: edit the CSS variables at the top of `css/style.css` (`--accent-1`, `--accent-2`…)
- Name/links: `js/config.js` (GitHub link) and `api/config.php`
- The token name/symbol are read live from the chain — no hardcoding needed.

## Troubleshooting

| Problem | Fix |
|---|---|
| "No wallet detected" | Install MetaMask; the site must be on https (Hostinger provides it) or localhost |
| "Could not read the contract" | Address/network mismatch — check Settings; make sure the token is deployed on that chain |
| Wrong network | The site prompts to switch on connect; or Settings → choose the network |
| Events empty | The feed looks back `eventLookbackBlocks` (50,000) — new tokens show nothing until first tx |
