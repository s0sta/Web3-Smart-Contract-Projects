# Security Policy

## Reporting a vulnerability

If you discover a security issue in any project in this repository, please report it
responsibly:

1. Open a **private vulnerability report** on GitHub
   (Security tab → Report a vulnerability), or
2. Contact [@s0sta](https://github.com/s0sta) directly.

Please include:

- The project and file(s) affected
- A description of the vulnerability and its potential impact
- A proof-of-concept or reproduction steps, if possible
- Your severity assessment (Critical / High / Medium / Low / Informational)

I aim to acknowledge reports within 48 hours and provide a fix or full response within one week.

## Scope

This repository is a **portfolio of educational smart-contract projects**. They are not
intended for production deployment with real funds as-is. The in-scope components are:

- `src/` contracts of all 10 projects
- `frontend/` dApp of project 01

## Secure development practices used

- From-scratch implementations that mirror battle-tested (OpenZeppelin/Uniswap/Synthetix) semantics
- Unit + fuzz test suites (251 tests) run in CI on every push
- Live attack proofs: reentrancy attempts (projects 02, 04), flash-vote-buying (project 09)
- Checks-effects-interactions, pull payments, and reentrancy guards throughout
- No mainnet deployments; testnet (Sepolia) only

## Known considerations

Each project README has a **"Production hardening"** section listing exactly what to swap
or add before any real-funds deployment (e.g. OpenZeppelin equivalents, oracles, timelocks).
Deploying any of these contracts to mainnet without modification and without an independent
audit is not recommended.
