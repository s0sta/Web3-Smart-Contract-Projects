/* ============================================================
   Genesis Collection dApp — end-to-end smoke test (Node, no npm)
   Verifies the EXACT bundles the site uses (ethers v6 UMD + the
   shipped js/abi.js) against any deployed GenesisNFT:

     1. anvil                        (terminal 1)
     2. forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
     3. NFT=0x… node smoke/smoke.js
   ============================================================ */

const fs = require("fs");
const os = require("os");
const path = require("path");

const ETHER_VERSION = "6.13.4";
const ETHER_CDN = `https://cdn.jsdelivr.net/npm/ethers@${ETHER_VERSION}/dist/ethers.umd.min.js`;

const RPC = process.env.RPC || "http://127.0.0.1:8545";
const NFT = process.env.NFT;
const OWNER_KEY = process.env.OWNER_KEY || "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"; // anvil #0
const USER_KEY = process.env.USER_KEY || "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"; // anvil #1

async function loadEthers() {
  const tmp = path.join(os.tmpdir(), `ethers-${ETHER_VERSION}.umd.min.js`);
  if (!fs.existsSync(tmp)) {
    console.log("Downloading ethers UMD (same bundle the site loads)…");
    const res = await fetch(ETHER_CDN);
    if (!res.ok) throw new Error("ethers download failed: " + res.status);
    fs.writeFileSync(tmp, Buffer.from(await res.arrayBuffer()));
  }
  return require(tmp);
}

/* merkle helpers — mirror of the contract's MerkleProof semantics */
function leaf(addr) {
  return ethers.keccak256(ethers.solidityPacked(["address"], [addr]));
}
function hashPair(a, b) {
  return a <= b
    ? ethers.keccak256(ethers.concat([a, b]))
    : ethers.keccak256(ethers.concat([b, a]));
}
function computeRoot(accounts) {
  let layer = accounts.map(leaf);
  while (layer.length > 1) {
    const next = [];
    for (let i = 0; i < layer.length; i += 2) {
      const right = i + 1 < layer.length ? layer[i + 1] : layer[i];
      next.push(hashPair(layer[i], right));
    }
    layer = next;
  }
  return layer[0];
}
function computeProof(accounts, index) {
  let layer = accounts.map(leaf);
  let idx = index;
  const proof = [];
  while (layer.length > 1) {
    const siblingIdx = idx % 2 === 0 ? idx + 1 : idx - 1;
    proof.push(siblingIdx < layer.length ? layer[siblingIdx] : layer[idx]);
    const next = [];
    for (let i = 0; i < layer.length; i += 2) {
      const right = i + 1 < layer.length ? layer[i + 1] : layer[i];
      next.push(hashPair(layer[i], right));
    }
    layer = next;
    idx = Math.floor(idx / 2);
  }
  return proof;
}

let passed = 0;
let failed = 0;
function check(label, cond, extra) {
  if (cond) { passed++; console.log("  ✔ " + label); }
  else { failed++; console.log("  ✘ " + label + (extra ? "  → " + extra : "")); }
}

async function main() {
  if (!NFT) {
    console.error("Usage: NFT=0x… node smoke/smoke.js");
    process.exit(2);
  }
  const ethers = await loadEthers();
  globalThis.ethers = ethers; // expose for the merkle helpers above

  global.window = {};
  require(path.join(__dirname, "..", "js", "abi.js"));
  const ABI = window.GENESIS_NFT_ABI;

  const provider = new ethers.JsonRpcProvider(RPC);
  const owner = new ethers.Wallet(OWNER_KEY, provider);
  const user = new ethers.Wallet(USER_KEY, provider);

  const nft = new ethers.Contract(NFT, ABI, owner);
  const iface = new ethers.Interface(ABI);

  console.log("== reads ==");
  check("name", (await nft.name()) === "Genesis");
  check("symbol", (await nft.symbol()) === "GEN");
  check("max supply 5000", (await nft.MAX_SUPPLY()) === 5000n);
  check("owner correct", (await nft.owner()).toLowerCase() === owner.address.toLowerCase());
  // reset mutable config so the test is re-runnable against the same deployment
  await (await nft.setRoyalty(owner.address, 500)).wait();
  await (await nft.setRevealed(false)).wait();
  check("default royalty 5%", (await nft.royaltyBps()) === 500n);

  console.log("== reserve mint + reveal ==");
  // fresh minter per run (per-wallet caps accumulate across runs otherwise)
  const fresh = ethers.Wallet.createRandom().connect(provider);
  await (await owner.sendTransaction({ to: fresh.address, value: ethers.parseEther("0.5") })).wait();

  const supplyBefore = await nft.totalSupply();
  await (await nft.ownerMint(fresh.address, 3)).wait();
  check("3 minted", (await nft.totalSupply()) === supplyBefore + 3n);
  check(
    "token ids sequential",
    (await nft.ownerOf(supplyBefore)) === fresh.address && (await nft.ownerOf(supplyBefore + 2n)) === fresh.address
  );

  await (await nft.setPrerevealURI("ipfs://prereveal")).wait();
  check("prereveal URI", (await nft.tokenURI(0)) === "ipfs://prereveal");
  await (await nft.setBaseURI("ipfs://base/")).wait();
  await (await nft.setRevealed(true)).wait();
  check("revealed URI", (await nft.tokenURI(0)) === "ipfs://base/0.json");

  console.log("== public mint ==");
  await (await nft.setPhase(2)).wait();
  const pubPrice = await nft.PUBLIC_PRICE();
  await (await nft.connect(fresh).mintPublic(2, { value: pubPrice * 2n })).wait();
  check("fresh owns 5", (await nft.balanceOf(fresh.address)) === 5n);
  check("supply +2", (await nft.totalSupply()) === supplyBefore + 5n);

  console.log("== whitelist mint (Merkle) ==");
  const accounts = [fresh.address, "0x1111111111111111111111111111111111111111", "0x2222222222222222222222222222222222222222"];
  await (await nft.setMerkleRoot(computeRoot(accounts))).wait();
  await (await nft.setPhase(1)).wait();
  const proof = computeProof(accounts, 0);
  const wlPrice = await nft.WHITELIST_PRICE();
  await (await nft.connect(fresh).mintWhitelist(proof, 1, { value: wlPrice })).wait();
  check("whitelist mint works", (await nft.balanceOf(fresh.address)) === 6n);

  console.log("== royalties ==");
  await (await nft.setRoyalty(owner.address, 750)).wait();
  const [, amount] = await nft.royaltyInfo(0, ethers.parseEther("1"));
  check("royalty 7.5%", amount === ethers.parseEther("0.075"));

  console.log("== withdraw ==");
  await (await nft.withdraw()).wait();
  check("balance drained", (await provider.getBalance(NFT)) === 0n);

  console.log("== error decoding (same as the dApp) ==");
  await (await nft.setPhase(0)).wait(); // Closed
  try {
    await nft.connect(fresh).mintPublic(1, { value: pubPrice });
    check("closed phase reverts", false, "should have reverted");
  } catch (err) {
    const e = iface.parseError(err.data);
    check("PhaseNotActive decoded", e && e.name === "PhaseNotActive", e && e.name);
  }
  await (await nft.setPhase(2)).wait();
  try {
    await nft.connect(fresh).mintPublic(1, { value: 1n });
    check("wrong value reverts", false, "should have reverted");
  } catch (err) {
    const e = iface.parseError(err.data);
    check("IncorrectValue decoded", e && e.name === "IncorrectValue", e && e.name);
  }

  console.log("== event feed (the dApp's getLogs flow) ==");
  const latest = await provider.getBlockNumber();
  const logs = await provider.getLogs({ address: NFT, fromBlock: 0, toBlock: latest });
  const decoded = logs.map((l) => { try { return iface.parseLog(l); } catch { return null; } }).filter(Boolean);
  const names = decoded.map((d) => d.name);
  for (const n of ["Transfer", "PhaseChanged", "Revealed", "RoyaltySet", "MerkleRootSet", "Withdrawn"]) {
    check(n + " present", names.includes(n));
  }

  console.log("\n" + (failed === 0 ? "SMOKE TEST PASSED" : "SMOKE TEST FAILED") + " — " + passed + " passed, " + failed + " failed");
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
