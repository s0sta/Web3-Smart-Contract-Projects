# Huwiyya dApp — Frontend for s0sta.com/huwiyya

The hosted identity wallet for the platform (Project 23): your DID card,
credentials, attestations, reputation and governance. No build step — pure
HTML/CSS/JS with ethers v6 UMD.

Live: **https://s0sta.com/huwiyya**

## Features

- 🔌 Wallet connect, network badge, settings, read-only mode
- 🪪 **DID card** — your identity, active status, reputation score and band
- 🎫 **Credentials** — your credentials with live validity; issue new ones
- ⭐ **Attestations & reputation** — your weighted score; submit attestations
- 🚪 **Gates & governance** — vote on and execute proposals
- ✨ Alabaster & iris "identity wallet" light theme, layout #19
- ⚠️ Decoded errors (`UnknownDid`, `AlreadyRevoked`, `CredentialExpired`,
  `NotGuardian`, `Timelocked`, …)

## Deploy

```bash
cd 23-huwiyya-identity
export DEPLOYER_PRIVATE_KEY=0x…
forge script script/Deploy.s.sol --rpc-url https://ethereum-sepolia-rpc.publicnode.com --broadcast
```

## Hosting (s0sta.com/huwiyya)

1. hPanel → **Files → File Manager** → `public_html/huwiyya`
2. Upload the **contents of `frontend/`** into it
3. Pre-filled configs: `js/config.js` + `api/config.php`
4. Verify: `https://s0sta.com/huwiyya/api/health.php`

## Self-test

```bash
anvil
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
cd frontend/smoke && node smoke.js
```
