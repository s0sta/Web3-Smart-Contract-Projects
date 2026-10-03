# 11 · JOP Governance — Owners Association Protocol (Dubai Law No. 6 of 2019)

![Solidity](https://img.shields.io/badge/Solidity-0.8.26-363636?logo=solidity&logoColor=white)
![Foundry](https://img.shields.io/badge/Foundry-1.5.1-8b5cf6)
![License](https://img.shields.io/badge/License-MIT-green)
![Tests](https://img.shields.io/badge/tests-48%20green-22c55e)
![Live](https://img.shields.io/badge/Live-s0sta.com%2Fhoa-d4a373)

<p align="center">
  <img src="../assets/hoa.svg" alt="JOP Owners Association — on-chain governance" width="100%" />
</p>

> **Difficulty: ★★★★★** · Flagship project — a real-world governance protocol inspired by the
> **United Arab Emirates' jointly owned property regime**, engineered to be portable to
> condominium/HOA frameworks in any jurisdiction.
>
> 🌐 **Live demo: [https://s0sta.com/hoa](https://s0sta.com/hoa)** — see [`frontend/README.md`](frontend/README.md).
>
> 📍 **Deployed on Sepolia: [`OwnersAssociationGovernor 0xFeD940A0435816f3f190f99737676F6A62Ba4228`](https://sepolia.etherscan.io/address/0xFeD940A0435816f3f190f99737676F6A62Ba4228)** · registry `0xb7Ab…0003F` · treasury `0xa339…100Da` · AED-S `0x6f79…7Dbe` · "Marina Heights Residences" (8 units / 610 sqm) · proposal #0 active with 180 sqm for

## The real-world scenario

In Dubai, every jointly owned building is governed under **Law No. 6 of 2019** (Jointly Owned
Property) and RERA's implementing guidance: unit owners vote **in proportion to their unit area**,
an **owners association board** administers the building, **service charges** fund the operation,
and decisions require **statutory quorums**. This project puts that entire legal workflow
on-chain:

| Legal concept (Law No. 6 of 2019 / RERA) | On-chain implementation |
|---|---|
| Unit register with area & ownership | `JOPUnitRegistry` — area-weighted ledger, sale registration |
| One owner, votes by area | snapshot voting power (`Checkpoints` history per owner) |
| Annual general meeting (AGM) | proposal lifecycle: review → vote → timelock → execute |
| Statutory quorums by decision type | per-proposal-type quorums (basis points of total area) |
| Board of managers | 5-seat board: fast-track, register sales, propose emergencies |
| Regulatory oversight | compliance role with a **binding veto** (RERA-style backstop) |
| Service-charge collection | per-sqm annual charge, linear accrual, arrears tracking |
| Association funds protection | treasury with a **minimum reserve**, payment ceilings, audit events |
| Civil Defence urgent works | Emergency proposals — board-only, skip the timelock |
| Proxy voting at meetings | delegable, expiring proxy votes with snapshot consistency |

**Portability**: the same architecture maps to HOA acts (US), Strata Schemes (Australia), Commonhold
(UK), and Condominium laws elsewhere — only the quorum table, period lengths and role labels change,
all of which are governance-settable on-chain (see the parameter setters).

## Contracts

| Contract | Path | Responsibility |
|---|---|---|
| `OwnersAssociationGovernor` | [`src/OwnersAssociationGovernor.sol`](src/OwnersAssociationGovernor.sol) | proposals, voting, veto, elections, emergency, delegation |
| `JOPUnitRegistry` | [`src/JOPUnitRegistry.sol`](src/JOPUnitRegistry.sol) | units, areas, ownership snapshots, service charges |
| `TreasuryVault` | [`src/TreasuryVault.sol`](src/TreasuryVault.sol) | reserve-enforced payments, ceilings, guardian drain |
| `AccessControl` | [`src/AccessControl.sol`](src/AccessControl.sol) | from-scratch RBAC (board / compliance / guardian) |
| `Checkpoints` | [`src/lib/Checkpoints.sol`](src/lib/Checkpoints.sol) | O(log n) snapshot voting-power history |
| `MockStable` | [`src/MockStable.sol`](src/MockStable.sol) | AED-S demo stable for charges & payments |

### Proposal types

| Type | Quorum (bps of area) | Who proposes | Notes |
|---|---|---|---|
| Budget | 20% | any owner ≥ threshold | maintenance allocations |
| ChargeRate | 30% | any owner ≥ threshold | must call `registry.setAnnualChargePerSqm` |
| Contract | 20% | any owner ≥ threshold | vendor awards |
| Rules | 30% | any owner ≥ threshold | quorum/period/threshold changes |
| Election | 20% | any owner ≥ threshold | must call `governor.setBoardMember` |
| Payment | 15% | any owner ≥ threshold | treasury disbursement (target must be the treasury) |
| Emergency | 15% | **board only** | no timelock — Civil Defence items |

### Security model

- **Separation of powers** — the governor holds no funds; payments execute *into* the treasury;
  the registry is the only owner of the ledger; roles are segregated (board / compliance / guardian)
- **Structural target allowlist** — proposals can only target the registry, the treasury, or the
  governor itself; per-type selector validation kills calldata-spoofing
- **CEI everywhere** — `executed` flips before external calls; reentrancy-safe by construction
- **Snapshot at block − 1** — no mint-then-propose / buy-then-vote attacks
- **Statutory reserve** — no payment (governance-executed included) may breach the treasury reserve;
  only the guardian's emergency drain bypasses it
- **Emergency brake** — the guardian can pause proposals and voting; compliance keeps a permanent veto

## Quick start

```bash
forge test           # 48 tests: registry, treasury, full governance lifecycle
forge build

# local demo deployment ("Marina Heights Residences", 8 units / 610 sqm)
anvil
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast

# Sepolia
export DEPLOYER_PRIVATE_KEY=0x…
forge script script/Deploy.s.sol --rpc-url https://ethereum-sepolia-rpc.publicnode.com --broadcast -vvvv
```

The deploy script registers the demo building, seats the board, appoints the compliance officer and
guardian, then **renounces the deployer's admin role** — the association governs itself from block one.

## Test coverage (48 tests)

- **Registry** — units, area transfers, historical snapshot power, linear charge accrual, sale-time
  accrual, charge payments to the treasury, overpay/zero guards
- **Treasury** — reserve enforcement, 30-day board payment ceilings, maintenance allocations,
  guardian drain, protected-token recovery
- **Governor** — proposal thresholds & board bypass, per-type calldata/target validation, veto,
  fast-track, weighted voting, double/late voting, delegation (transfer/expiry/revoke/sale-adjust),
  full pass→timelock→execute lifecycle, defeat by quorum, emergency without timelock, board
  elections, parameter changes via Rules, unit-sale registration, pause/unpause, state matrix

## Production hardening (before real deployments)

- Replace `MockStable` with a regulated AED-pegged stablecoin and add a price/valuation oracle for
  service-charge settlement
- Add identity/KYC layers required by the property regulator and the building's service provider
- Consider a UUPS upgrade path for the quorum table once the association's bylaws evolve
- Independent audit — this is portfolio work demonstrating engineering methodology

## License

MIT — see [LICENSE](../LICENSE).
