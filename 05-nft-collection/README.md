# 05 · GenesisNFT — NFT Collection with Merkle Whitelist & Royalties

![Solidity](https://img.shields.io/badge/Solidity-0.8.26-363636?logo=solidity&logoColor=white)
![Foundry](https://img.shields.io/badge/Foundry-1.5.1-8b5cf6)
![License](https://img.shields.io/badge/License-MIT-green)
![Live](https://img.shields.io/badge/Live-s0sta.com/nft-ec4899)

<p align="center">
  <img src="../assets/nft.svg" alt="Genesis Collection — ERC-721 from scratch" width="100%" />
</p>

> **Difficulty: ★★★☆☆** · Project 5 of the [Web3 Smart Contract Projects](../README.md) portfolio.
>
> 🌐 **Live demo: [https://s0sta.com/nft](https://s0sta.com/nft)** — a full dApp dashboard for this collection (see [`frontend/`](frontend/README.md)).
>
> 📍 **Deployed on Sepolia: [`GenesisNFT 0x57446cB7B0E8ac94892A5cB2b61C8cb377BC7Fea`](https://sepolia.etherscan.io/address/0x57446cB7B0E8ac94892A5cB2b61C8cb377BC7Fea)** · owner `0x319899FaAAD730519B8a2Bd72d2Eba2370a9B853` · 5 minted · public phase live

A complete NFT drop written **from scratch — including the ERC-721 implementation itself**:
Merkle-tree whitelist phase, public phase, per-wallet caps, owner reserve, ERC-2981 royalties
and a pre/post-reveal metadata flow.

---

## Features

- ✅ **ERC-721 written from scratch** — ownership, approvals, operator approvals, safe transfers
  with the `onERC721Received` receiver check, ERC-165 introspection
- ✅ **Merkle whitelist** — gas-efficient allowlist; the Merkle proof verifier is also hand-written
- ✅ **Two mint phases** — whitelist (0.05 ETH, max 2/wallet) → public (0.08 ETH, max 10/wallet)
- ✅ **Owner reserve** — team mints still respect the 5000 supply cap
- ✅ **Reveal flow** — placeholder metadata until the owner flips `revealed`
- ✅ **ERC-2981 royalties** — marketplaces pay the artist on every sale (5% default, capped at 10%)
- ✅ **Withdrawal** of all mint revenue to the owner, reentrancy-guarded
- ✅ **Custom errors + full NatSpec**

## Architecture

| Contract | File | Purpose |
|---|---|---|
| `ERC721` | [`src/ERC721.sol`](src/ERC721.sol) | The token standard itself, from scratch |
| `MerkleProof` | [`src/MerkleProof.sol`](src/MerkleProof.sol) | Whitelist proof verification |
| `GenesisNFT` | [`src/GenesisNFT.sol`](src/GenesisNFT.sol) | Collection: phases, caps, royalties, reveal |
| `Ownable` / `ReentrancyGuard` | [`src/`](src) | Shared primitives |
| `DeployGenesisNFT` | [`script/Deploy.s.sol`](script/Deploy.s.sol) | Deployment (root/URI wiring commented inline) |
| `frontend/` | [`frontend/README.md`](frontend/README.md) | The hosted dApp (s0sta.com/nft) |

## Flow

```
CLOSED ──setPhase()──► WHITELIST ──setPhase()──► PUBLIC
                         │  mintWhitelist(proof, qty)   mintPublic(qty)
                         │  · Merkle proof required     · public price
                         │  · 0.05 ETH × qty            · max 10/wallet
                         │  · max 2/wallet
                         ▼
              metadata: prerevealURI ──setRevealed(true)──► baseURI + id + .json
              royalties: royaltyInfo() → 5% to owner (marketplaces)
```

## Quickstart

```bash
forge build     # compile
forge test      # run all tests
forge snapshot  # gas report
```

## Deploy

```bash
anvil
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast -vvvv
```

Whitelist roots are computed off-chain (see the test helpers for a pure-Solidity reference
implementation, or use `merkletreejs` / OpenZeppelin's `MerkleTree`).

## Test coverage

| Group | What it proves |
|---|---|
| Metadata | name/symbol/supply; ERC-165/721/2981 introspection |
| Owner reserve | sequential ids, owner-only, supply cap, zero quantity |
| Whitelist | valid proofs mint; per-wallet cap; wrong proof/wrong leaf/proof reuse rejected; wrong value; wrong phase |
| Public | exact payment math; per-wallet cap; supply cap; phase gates |
| Phases | Closed blocks everything; owner-only transitions |
| Royalties | 5% math, updates, 10% cap, zero-address rejection |
| Reveal | prereveal → revealed URI; nonexistent token reverts |
| Transfers | approve/transferFrom, operator approvals, safe-transfer receiver check (accepting + rejecting contracts) |
| Withdraw | full balance to owner; owner-only |
| **Fuzz** | royalty math over arbitrary sale prices; exact-payment mints |

## Design decisions

- **Why implement ERC-721 by hand?** The standard is the product here — knowing exactly how
  ownership, approvals and the receiver check work is what separates auditors from users.
  The implementation follows OpenZeppelin's semantics closely so it swaps in 1:1.
- **Merkle over array.** Storing the whitelist on-chain costs gas per entry; a single
  `bytes32` root scales to unlimited whitelists for free.
- **Per-wallet caps counted separately per phase** — whitelist buyers can also buy in public,
  a deliberate product choice.
- **Royalties default to the owner** — the artist *is* the deployer in the common case.

## Production hardening

- Swap `ERC721`/`Ownable`/`ReentrancyGuard`/`MerkleProof` for OpenZeppelin equivalents
  (the APIs match intentionally)
- Use the dedicated `MerkleTree` tooling + EIP-712 signatures for gasless whitelist mints
- Consider `paymentSplitter` for multi-recipient revenue, and timelocked phases

## Security considerations

- Sequential token ids leak nothing sensitive but do reveal total minted — fine for this use case.
- `withdraw` sends to the owner address — if ownership was transferred to a contract without
  `receive()`, withdrawals would fail; the two-step `Ownable` transfer mitigates accidental cases.
- Proof reuse across wallets is impossible: the leaf is `keccak256(msg.sender)`.

## What this project taught me

The ERC-721 standard internals, Merkle tree construction *and* verification, phase-gated minting
economics, royalty standards, and metadata reveal patterns — the exact stack behind every
successful NFT launch.

## License

[MIT](LICENSE)
