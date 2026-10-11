# Shifa dApp — frontend

The care console for Project 28: patient-owned records, consent, prescriptions,
visits, health cover and reputation. No build step — plain HTML/CSS/JS with
ethers v6 (UMD).

Live: **https://s0sta.com/Web3-Smart-Contract-Projects/shifa/**

## What you can do

- 🪪 **Join & consent** — register as patient, doctor, clinic, pharmacist or
  insurer; patients grant scoped, time-limited access and revoke any time
- 📋 **Medical records** — clinicians file document fingerprints; reading is
  gated by consent and emits a read event
- 💊 **Prescriptions** — issue with dose, refills and validity; dispensaries
  consume refills one at a time
- 📅 **Visits** — book with a deposit, complete, cancel or mark a no-show, then rate
- 🛡 **Health cover** — subscribe to a plan (yearly limit + copay), see claims and
  settle your copay after the two-of-three reviewers approve
- 🔀 **How-to, on-chain process and a flow graph** are inside `index.html`

## Theme

Surgical teal & vital coral "care console" (dark) — layout #23, with a vitals
strip at the top and a three-column care grid.

## Run it locally

```bash
# 1. chain + contracts
anvil
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast

# 2. point the dApp at your local network
#    open frontend/js/config.js and set the addresses, or paste the registry
#    address into the banner in the browser

# 3. serve the folder
python3 -m http.server 8080 --directory frontend

# 4. end-to-end check (fresh anvil)
cd frontend/smoke && node smoke.js
```

## Hosting

Upload the **contents of `frontend/`** into the folder that serves
`/Web3-Smart-Contract-Projects/shifa/` and confirm `api/health.php` answers.
Addresses are pre-filled in `js/config.js` after each deployment.
