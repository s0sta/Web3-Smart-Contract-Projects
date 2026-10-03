# Genesis Collection dApp — Frontend for nft.s0sta.com

A modern, self-contained web3 dashboard for the GenesisNFT collection (Project 05).
**No build step, no Node server** — pure HTML/CSS/JS with ethers.js v6 from a CDN,
plus an optional tiny PHP config layer. Uploads directly to any PHP/static hosting.

Live: **https://nft.s0sta.com**

> ✅ **Already deployed on Sepolia** — the config files below are pre-filled.
> Just upload this folder to Hostinger and the site is live.

---

## Features

- 🔌 **Wallet connect** (MetaMask / any EIP-1193 wallet), auto-reconnect, network badge & switching
- 🪙 **Public mint** — exact price + per-wallet cap shown, one click
- 🌳 **Whitelist mint** — paste your Merkle proof (32-byte hex per line), quantity, exact price
- 🖼 **Live gallery** — recent mints as tiles: real metadata images via IPFS gateway when available,
  holographic gradient placeholders otherwise, 🔒 lock overlay pre-reveal, click → OpenSea testnet
- 📊 **Collection stats** — minted/max supply, phase badge (Closed / Whitelist / Public), revealed status, royalty, your balance
- 👑 **Owner panel** — set phase, Merkle root, base/pre-reveal URIs, toggle reveal, set royalties, reserve mint, withdraw
- 📜 **Live activity feed** — Transfer (mint detection), PhaseChanged, Revealed, RoyaltySet, MerkleRootSet, Withdrawn
- ⚠️ **Human-readable errors** — `PhaseNotActive()`, `IncorrectValue()`, `InvalidProof()`, `ExceedsMaxPerWallet()` decoded
- ✨ Pink & lime "neon gallery" theme: twinkling star field, holographic tile spins, shine-sweep mint buttons, reveal flash
- 🍞 Toasts, copy-to-clipboard, read-only mode without a wallet, responsive layout

## File structure

```
frontend/
├── index.html          # the whole page
├── css/style.css       # pink/lime neon gallery theme + motion language
├── js/abi.js           # GenesisNFT ABI (auto-generated from forge build)
├── js/config.js        # collection address + network + IPFS gateway config
├── js/app.js           # all dApp logic
├── smoke/smoke.js      # end-to-end self-test (Node, no npm)
└── api/
    ├── config.php      # OPTIONAL server-side config (sets collection address on Hostinger)
    └── health.php      # health check endpoint
```

### Self-test the frontend against your deployment

```bash
anvil                                                        # terminal 1
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast   # terminal 2
cd frontend && NFT=0x… node smoke/smoke.js   # mint/reveal/royalty/withdraw/whitelist/errors/events
```

---

## 1. Deploy the collection (Sepolia testnet)

```bash
cd 05-nft-collection         # from the repo root

export DEPLOYER_PRIVATE_KEY=0x…
export SEPOLIA_RPC=https://ethereum-sepolia-rpc.publicnode.com

forge script script/Deploy.s.sol \
  --rpc-url $SEPOLIA_RPC \
  --broadcast \
  -vvvv

# post-deploy wiring (the script logs placeholders for these):
#   setPrerevealURI / setBaseURI / setMerkleRoot / setPhase — or use the dApp's owner panel
```

### Local demo (no testnet ETH needed)

```bash
anvil                                                       # terminal 1
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

Then open the dApp → Settings → Network: Local (Anvil) → paste the collection address.

## 2. Configure the dApp

| Where | What |
|---|---|
| `js/config.js` | set `nftAddress`, `defaultChainId` and `ipfsGateway` (ships in the repo) |
| `api/config.php` | set `nftAddress` — takes priority when hosted on PHP |
| Browser UI | Settings ⚙ saves the address in localStorage |

## 3. Upload to Hostinger (subdomain nft.s0sta.com)

1. hPanel → **Domains → Subdomains**, create `nft` pointing at your domain.
2. Upload the **contents of `frontend/`** into the subdomain's document root.
3. Edit `api/config.php` (or `js/config.js` before uploading) and paste the collection address.
4. Open `https://nft.s0sta.com` — done. Verify PHP via `https://nft.s0sta.com/api/health.php`.

## 4. Reference the live site from GitHub

> Live demo: https://nft.s0sta.com · Sepolia testnet · ERC-721 in `src/`

## Rebranding

- Colors: CSS variables at the top of `css/style.css` (`--accent-1` pink, `--accent-2` lime)
- Motion: tweak `holoSpin`, `twinkle`, `btnSheen`, `revealFlash` keyframes
- Links: `js/config.js` + `api/config.php`

## Troubleshooting

| Problem | Fix |
|---|---|
| "No wallet detected" | Install MetaMask; site must be on https or localhost |
| "Could not read the collection" | Address/network mismatch — check Settings |
| Gallery tiles show gradients | Metadata fetch failed or pre-reveal — expected behavior, try another IPFS gateway in config |
| Whitelist mint reverts | Your proof must be for YOUR address (leaf = keccak256(address)) and the phase must be Whitelist |
