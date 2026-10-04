/* ============================================================
   TrustEscrow dApp — end-to-end smoke test (Node, no npm)
   Verifies the EXACT bundles the site uses (ethers v6 UMD + the
   shipped js/abi.js) against any deployed TrustEscrow:

     1. anvil                        (terminal 1)
     2. forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
     3. ESCROW=0x… node smoke/smoke.js
   ============================================================ */

const fs = require("fs");
const os = require("os");
const path = require("path");

const ETHER_VERSION = "6.13.4";
const ETHER_CDN = `https://cdn.jsdelivr.net/npm/ethers@${ETHER_VERSION}/dist/ethers.umd.min.js`;

const RPC = process.env.RPC || "http://127.0.0.1:8545";
const ESCROW = process.env.ESCROW;
const BUYER_KEY = process.env.BUYER_KEY || "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"; // anvil #0 (also owner)
const SELLER_KEY = process.env.SELLER_KEY || "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"; // anvil #1
const ARBITER_KEY = process.env.ARBITER_KEY || "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"; // anvil #2

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

let passed = 0;
let failed = 0;
function check(label, cond, extra) {
  if (cond) { passed++; console.log("  ✔ " + label); }
  else { failed++; console.log("  ✘ " + label + (extra ? "  → " + extra : "")); }
}

async function main() {
  if (!ESCROW) {
    console.error("Usage: ESCROW=0x… node smoke/smoke.js");
    process.exit(2);
  }
  const ethers = await loadEthers();

  global.window = {};
  require(path.join(__dirname, "..", "js", "abi.js"));
  const ABI = window.TRUST_ESCROW_ABI;

  const provider = new ethers.JsonRpcProvider(RPC);
  const buyer = new ethers.Wallet(BUYER_KEY, provider);
  const seller = new ethers.Wallet(SELLER_KEY, provider);
  const arbiter = new ethers.Wallet(ARBITER_KEY, provider);

  const escrow = new ethers.Contract(ESCROW, ABI, buyer);
  const iface = new ethers.Interface(ABI);

  // reset platform fee so the test is re-runnable against the same deployment
  await (await escrow.setFeeBps(50)).wait();

  console.log("== reads ==");
  check("feeBps == 50", (await escrow.feeBps()) === 50n);
  check("owner correct", (await escrow.owner()).toLowerCase() === buyer.address.toLowerCase());
  const initialCount = Number(await escrow.dealCount());
  console.log("  (deals on chain:", initialCount + ")");

  console.log("== open & release ==");
  const t1 = await escrow.openDeal(seller.address, arbiter.address, { value: ethers.parseEther("1") });
  const r1 = await t1.wait();
  const opened = r1.logs.map((l) => { try { return iface.parseLog(l); } catch { return null; } }).find((l) => l && l.name === "DealOpened");
  check("DealOpened event", !!opened);
  const deal1 = Number(opened.args.dealId);
  const [b1, s1, a1, amt1, fee1, st1] = await escrow.deals(deal1);
  check("frozen fee == 50 bps", fee1 === 50n);
  check("state Active", Number(st1) === 0);

  const sellerBefore = await provider.getBalance(seller.address);
  const rel = await (await escrow.connect(seller).release(deal1)).wait();
  const releasedEv = rel.logs.map((l) => { try { return iface.parseLog(l); } catch { return null; } }).find((l) => l && l.name === "DealReleased");
  check("release event pays 0.995", releasedEv && releasedEv.args.amount === ethers.parseEther("0.995"));
  check("fee credited 0.005", (await escrow.accruedFees()) >= ethers.parseEther("0.005"));

  console.log("== refund flow ==");
  const t2 = await escrow.openDeal(seller.address, arbiter.address, { value: ethers.parseEther("0.5") });
  const r2 = await t2.wait();
  const opened2 = r2.logs.map((l) => { try { return iface.parseLog(l); } catch { return null; } }).find((l) => l && l.name === "DealOpened");
  const deal2 = Number(opened2.args.dealId);
  const ref = await (await escrow.refund(deal2)).wait();
  const refundedEv = ref.logs.map((l) => { try { return iface.parseLog(l); } catch { return null; } }).find((l) => l && l.name === "DealRefunded");
  check("refund event pays full 0.5", refundedEv && refundedEv.args.amount === ethers.parseEther("0.5"));

  console.log("== dispute & resolve ==");
  const t3 = await escrow.openDeal(seller.address, arbiter.address, { value: ethers.parseEther("1") });
  const r3 = await t3.wait();
  const opened3 = r3.logs.map((l) => { try { return iface.parseLog(l); } catch { return null; } }).find((l) => l && l.name === "DealOpened");
  const deal3 = Number(opened3.args.dealId);
  await (await escrow.dispute(deal3)).wait();
  check("state Disputed", Number((await escrow.deals(deal3))[5]) === 3);

  const bBefore = await provider.getBalance(buyer.address);
  const sBefore = await provider.getBalance(seller.address);
  await (await escrow.connect(arbiter).resolve(deal3, ethers.parseEther("0.4"))).wait();
  // buyer 0.4 · fee 0.005 · seller 0.595
  check("buyer got 0.4", (await provider.getBalance(buyer.address)) - bBefore === ethers.parseEther("0.4"));
  check("seller got 0.595", (await provider.getBalance(seller.address)) - sBefore === ethers.parseEther("0.595"));
  check("state Resolved", Number((await escrow.deals(deal3))[5]) === 4);

  console.log("== frozen fee vs new fee ==");
  await (await escrow.setFeeBps(500)).wait();
  const t4 = await escrow.openDeal(seller.address, arbiter.address, { value: ethers.parseEther("1") });
  const r4 = await t4.wait();
  const opened4 = r4.logs.map((l) => { try { return iface.parseLog(l); } catch { return null; } }).find((l) => l && l.name === "DealOpened");
  const deal4 = Number(opened4.args.dealId);
  check("new deal frozen at 500 bps", (await escrow.deals(deal4))[4] === 500n);

  console.log("== error decoding (same as the dApp) ==");
  try {
    await escrow.connect(buyer).release(deal4);
    check("buyer release reverts", false, "should have reverted");
  } catch (err) {
    const e = iface.parseError(err.data);
    check("NotSeller decoded", e && e.name === "NotSeller", e && e.name);
  }
  try {
    await escrow.connect(buyer).refund(deal3);
    check("refund resolved deal reverts", false, "should have reverted");
  } catch (err) {
    const e = iface.parseError(err.data);
    check("NotActive decoded", e && e.name === "NotActive", e && e.name);
  }

  console.log("== event feed (the dApp's getLogs flow) ==");
  const latest = await provider.getBlockNumber();
  const logs = await provider.getLogs({ address: ESCROW, fromBlock: 0, toBlock: latest });
  const decoded = logs.map((l) => { try { return iface.parseLog(l); } catch { return null; } }).filter(Boolean);
  const names = decoded.map((d) => d.name);
  for (const n of ["DealOpened", "DealReleased", "DealRefunded", "DisputeRaised", "DisputeResolved", "FeeCredited", "FeeBpsUpdated"]) {
    check(n + " present", names.includes(n));
  }

  console.log("\n" + (failed === 0 ? "SMOKE TEST PASSED" : "SMOKE TEST FAILED") + " — " + passed + " passed, " + failed + " failed");
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
