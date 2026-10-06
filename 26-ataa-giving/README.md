# 26 · Ataa — Zakat & Giving Platform with Donor Tracking

![Solidity](https://img.shields.io/badge/Solidity-0.8.26-363636?logo=solidity&logoColor=white)
![Foundry](https://img.shields.io/badge/Foundry-1.5.1-8b5cf6)
![License](https://img.shields.io/badge/License-MIT-green)
![Tests](https://img.shields.io/badge/tests-36%20green-22c55e)
![Live](https://img.shields.io/badge/Live-s0sta.com%2Fataa-0d6e4f)

> **Difficulty: ★★★★★★** · The eighth flagship · 🌐 **Live demo: [https://s0sta.com/ataa](https://s0sta.com/ataa)**
> — see [`frontend/README.md`](frontend/README.md)
>
> 📍 **Deployed on Sepolia: [`AtaaRegistry 0xeE9fd5f7b8Eb2250963F3d948fEcfc62D5A02018`](https://sepolia.etherscan.io/address/0xeE9fd5f7b8Eb2250963F3d948fEcfc62D5A02018)** — 10 contracts live (registry, oracle, zakat, vault, donations, allocations, emergency, sponsorships, governor) · the owner's donor profile, the first beneficiary (orphan sponsorship) and a 100,000 SAR-S wealth declaration are live — a comprehensive charitable
> giving platform: a full zakat calculator across seven asset classes, sadaqa
> donations, **per-donation donor tracking** (see exactly where your money
> went), emergency campaigns, monthly sponsorships and donor governance.

## The real-world scenario

Ataa ("giving") turns the entire act of giving into a transparent, trackable
flow: a Muslim declares wealth per asset class, the platform computes nisab and
hawl and collects the correct zakat; anyone gives sadaqa; the committee
disburses to verified beneficiaries; and — uniquely — **every donor can trace
their own contribution to the exact disbursements it funded**.

| Giving function | Contract | Mechanism |
|---|---|---|
| Directory | `AtaaRegistry` | donors, KYC'd beneficiaries with needs, the zakat committee |
| Prices | `AtaaOracle` | EMA gold/silver feeds → nisab thresholds |
| Zakat intelligence | `AtaaZakat` | 7 asset classes, per-class rates (2.5/5/10/20%), nisab, hawl clocks with reset, partial payments, livestock schedules |
| Fund + provenance | `AtaaVault` | pooled fund; FIFO attribution of every disbursement to the donations that funded it; donor reports |
| Sadaqa | `AtaaDonations` | any-amount general giving with intent categories |
| Disbursements | `AtaaAllocations` | 2-of-3 committee, per-category budgets |
| Urgent relief | `AtaaEmergency` | campaigns with targets/deadlines, fast-track payouts |
| Monthly giving | `AtaaSponsorships` | donor–beneficiary adoption pledges with renewals, pause, cancel |
| Governance | `AtaaGovernor` | donor-weighted voting (quorum + timelock) |

## Security model

- **Zakat math on-chain** — nisab, hawl, rates and schedules are code, not
  spreadsheets; every edge case is a tested path
- **Provenance by construction** — the vault cannot disburse without
  attributing the outflow to real contributions (FIFO)
- **2-of-3 committee**, category budgets, active-beneficiary checks
- **Timelocked, allowlisted governance**

## Quick start

```bash
forge test    # 36 tests
forge build
anvil
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

## Production hardening

- Licensed zakat authorities for nisab calibration, fiat rails for real SAR,
  independent audit before real funds.

## License

MIT — see [LICENSE](../LICENSE).
