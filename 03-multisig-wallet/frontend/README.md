# MultiSig Vault dApp — Frontend for s0sta.com/multisig

A modern, self-contained web3 dashboard for the from-scratch MultiSigWallet (Project 03).
**No build step, no Node server** — pure HTML/CSS/JS with ethers.js v6 from a CDN,
plus an optional tiny PHP config layer. Uploads directly to any PHP/static hosting.

Live: **https://s0sta.com/multisig**

> ✅ **Already deployed on Sepolia** (2-of-3 wallet with demo owner keys) — the config
> files below are pre-filled. Just upload this folder to Hostinger and the site is live.

### 🎭 Play all three signer roles (MetaMask demo)

The Sepolia wallet is **2-of-3**. Import these two testnet-only demo keys into MetaMask
(Account → Import account) to confirm/execute from a second and third signer:

| Signer | Address | Private key (TESTNET ONLY — no real funds) |
|---|---|---|
| Owner 2 | `0xA83BF594C8df3D7208d41814d7b2cfCCe97CbE6b` | `0x42b5e461648a26e02378f67bc18e1085c0b9b73126eced15b8d821f8ecdbec8e` |
| Owner 3 | `0x49920240d7CF9D488Da63BF1B978f96a9D41AbD3` | `0x7aa036dba3efa9f6c57bde8d68494661e2bcb08aad6a455bf2379688008ab224` |

Owner 1 is your own wallet (`0x3198…9B853`). Both demo signers are pre-funded with Sepolia
ETH for gas. Never reuse these keys anywhere else.

---

## Features

- 🔌 **Wallet connect** (MetaMask / any EIP-1193 wallet), auto-reconnect, network badge & switching
- 🔐 **Vault overview** — live ETH balance, signer list with "you" badges, threshold (N-of-M), tx count
- 📮 **Propose transactions** — destination, ETH value, optional raw calldata (tokens, any call)
- 💍 **Threshold rings** — animated donut per transaction filling toward confirmations, glowing when met
- ✔ **Confirm / Revoke / Execute** for signers; executed & failed-retry states visible
- 🎚 **Change threshold** (signer panel)
- 💸 **Deposit ETH** straight from the UI
- 📜 **Live activity feed** — Deposit / Submission / Confirmation / Revocation / Execution / ExecutionFailure / ThresholdChanged
- ⚠️ **Human-readable errors** — `NotOwner()`, `AlreadyExecuted()`, `NotEnoughConfirmations()` decoded
- ✨ Indigo & sky "vault" theme: floating key-shards, sheen sweep on the vault logo, soft pulses, staggered entrances
- 🍞 Toasts, copy-to-clipboard, read-only mode without a wallet, responsive layout

## File structure

```
frontend/
├── index.html          # the whole page
├── css/style.css       # indigo/sky vault theme + motion language
├── js/abi.js           # MultiSigWallet ABI (auto-generated from forge build)
├── js/config.js        # wallet address + network config
├── js/app.js           # all dApp logic
├── smoke/smoke.js      # end-to-end self-test (Node, no npm)
└── api/
    ├── config.php      # OPTIONAL server-side config (sets wallet address on Hostinger)
    └── health.php      # health check endpoint
```

### Self-test the frontend against your deployment

```bash
anvil                                                        # terminal 1
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast   # terminal 2
cd frontend && WALLET=0x… node smoke/smoke.js    # submit/confirm/execute/failure-retry/revoke/threshold/events
```

---

## 1. Deploy the wallet (Sepolia testnet)

```bash
cd 03-multisig-wallet        # from the repo root

export DEPLOYER_PRIVATE_KEY=0x…          # owner #1
export OWNER_2=0x…                       # owner #2
export OWNER_3=0x…                       # owner #3
export SEPOLIA_RPC=https://ethereum-sepolia-rpc.publicnode.com

forge script script/Deploy.s.sol \
  --rpc-url $SEPOLIA_RPC \
  --broadcast \
  -vvvv
```

The script deploys a **2-of-3** wallet with the three addresses above.

### Local demo (no testnet ETH needed)

```bash
anvil                                                       # terminal 1
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

Then open the dApp → Settings → Network: Local (Anvil) → paste the wallet address.

## 2. Configure the dApp

| Where | What |
|---|---|
| `js/config.js` | set `walletAddress` and `defaultChainId` (ships in the repo) |
| `api/config.php` | set `walletAddress` — takes priority when hosted on PHP |
| Browser UI | Settings ⚙ saves the address in localStorage |

## 3. Upload to Hostinger (path s0sta.com/multisig)

1. hPanel → **Files → File Manager**, open your main domain's `public_html`.
2. Create the project folder and upload the **contents of `frontend/`** into it.
3. Edit `api/config.php` (or `js/config.js` before uploading) and paste the wallet address.
4. Open `https://s0sta.com/multisig` — done. Verify PHP via `https://s0sta.com/multisig/api/health.php`.

## 4. Reference the live site from GitHub

> Live demo: https://s0sta.com/multisig · Sepolia testnet · wallet in `src/`

## Rebranding

- Colors: CSS variables at the top of `css/style.css` (`--accent-1` indigo, `--accent-2` sky)
- Motion: tweak `shardFloat` / `sheen` / `softPulse` keyframes
- Links: `js/config.js` + `api/config.php`

## Troubleshooting

| Problem | Fix |
|---|---|
| "No wallet detected" | Install MetaMask; site must be on https or localhost |
| "Could not read the wallet" | Address/network mismatch — check Settings |
| Wrong network | The site prompts to switch on connect; or Settings → network |
| Buttons missing | Only signers see confirm/execute — the role is shown in the stats panel |
