/* ============================================================
   MultiSig Vault dApp — end-to-end smoke test (Node, no npm)
   Verifies the EXACT bundles the site uses (ethers v6 UMD + the
   shipped js/abi.js) against any deployed MultiSigWallet:

     1. anvil                        (terminal 1)
     2. forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
     3. WALLET=0x… node smoke/smoke.js
   ============================================================ */

const fs = require("fs");
const os = require("os");
const path = require("path");

const ETHER_VERSION = "6.13.4";
const ETHER_CDN = `https://cdn.jsdelivr.net/npm/ethers@${ETHER_VERSION}/dist/ethers.umd.min.js`;

const RPC = process.env.RPC || "http://127.0.0.1:8545";
const WALLET = process.env.WALLET;
const O1_KEY = process.env.O1_KEY || "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"; // anvil #0
const O2_KEY = process.env.O2_KEY || "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"; // anvil #1
const O3_KEY = process.env.O3_KEY || "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"; // anvil #2

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
  if (!WALLET) {
    console.error("Usage: WALLET=0x… node smoke/smoke.js");
    process.exit(2);
  }
  const ethers = await loadEthers();

  global.window = {};
  require(path.join(__dirname, "..", "js", "abi.js"));
  const ABI = window.MULTISIG_ABI;

  const provider = new ethers.JsonRpcProvider(RPC);
  const o1 = new ethers.Wallet(O1_KEY, provider);
  const o2 = new ethers.Wallet(O2_KEY, provider);
  const o3 = new ethers.Wallet(O3_KEY, provider);
  const outsider = new ethers.Wallet("0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba", provider);

  const wallet = new ethers.Contract(WALLET, ABI, o1);
  const iface = new ethers.Interface(ABI);

  console.log("== reads ==");
  check("threshold == 2", (await wallet.threshold()) === 2n);
  const owners = await wallet.getOwners();
  check("3 owners", owners.length === 3);

  console.log("== deposit ==");
  await (await o1.sendTransaction({ to: WALLET, value: ethers.parseEther("1") })).wait();
  check("wallet balance 1 ETH", (await provider.getBalance(WALLET)) === ethers.parseEther("1"));

  console.log("== submit & confirm ==");
  const recipient = "0x1111111111111111111111111111111111111111";
  const tx = await wallet.submitTransaction(recipient, ethers.parseEther("0.25"), "0x");
  const rc = await tx.wait();
  const sub = rc.logs.map((l) => { try { return iface.parseLog(l); } catch { return null; } }).find((l) => l && l.name === "Submission");
  check("Submission event", !!sub);
  const txId = Number(sub.args.txId);

  await (await wallet.confirmTransaction(txId)).wait();
  await (await wallet.connect(o2).confirmTransaction(txId)).wait();
  check("2 confirmations", Number(await wallet.getConfirmationCount(txId)) === 2);
  const confs = await wallet.getConfirmations(txId);
  check("confirmers listed", confs.length === 2 && confs.includes(o2.address));

  console.log("== revoke & re-confirm ==");
  await (await wallet.connect(o2).revokeConfirmation(txId)).wait();
  check("revoke drops count", Number(await wallet.getConfirmationCount(txId)) === 1);
  await (await wallet.connect(o2).confirmTransaction(txId)).wait();

  console.log("== execute ==");
  const balBefore = await provider.getBalance(recipient);
  await (await wallet.connect(o3).executeTransaction(txId)).wait();
  check("recipient got 0.25 ETH", (await provider.getBalance(recipient)) - balBefore === ethers.parseEther("0.25"));
  const [dest, , , executed] = await wallet.transactions(txId);
  check("executed flag", executed === true);

  console.log("== failure → retry ==");
  // value exceeds wallet balance → external call fails → ExecutionFailure, retryable
  const tx2 = await wallet.submitTransaction(recipient, ethers.parseEther("100"), "0x");
  const rc2 = await tx2.wait();
  const sub2 = rc2.logs.map((l) => { try { return iface.parseLog(l); } catch { return null; } }).find((l) => l && l.name === "Submission");
  const txId2 = Number(sub2.args.txId);
  await (await wallet.confirmTransaction(txId2)).wait();
  await (await wallet.connect(o2).confirmTransaction(txId2)).wait();
  const ex = await wallet.connect(o3).executeTransaction(txId2);
  const rce = await ex.wait();
  const failure = rce.logs.map((l) => { try { return iface.parseLog(l); } catch { return null; } }).find((l) => l && l.name === "ExecutionFailure");
  check("ExecutionFailure emitted", !!failure);
  const [, , , exec2] = await wallet.transactions(txId2);
  check("flag rolled back (retryable)", exec2 === false);

  console.log("== error decoding (same as the dApp) ==");
  try {
    await wallet.connect(outsider).confirmTransaction(txId2);
    check("non-owner confirm reverts", false, "should have reverted");
  } catch (err) {
    const e = iface.parseError(err.data);
    check("NotOwner decoded", e && e.name === "NotOwner", e && e.name);
  }
  try {
    await wallet.connect(o3).executeTransaction(txId);
    check("double execute reverts", false, "should have reverted");
  } catch (err) {
    const e = iface.parseError(err.data);
    check("AlreadyExecuted decoded", e && e.name === "AlreadyExecuted", e && e.name);
  }

  console.log("== change threshold ==");
  await (await wallet.changeThreshold(3)).wait();
  check("threshold now 3", (await wallet.threshold()) === 3n);
  await (await wallet.changeThreshold(2)).wait();

  console.log("== event feed (the dApp's getLogs flow) ==");
  const latest = await provider.getBlockNumber();
  const logs = await provider.getLogs({ address: WALLET, fromBlock: 0, toBlock: latest });
  const decoded = logs.map((l) => { try { return iface.parseLog(l); } catch { return null; } }).filter(Boolean);
  const names = decoded.map((d) => d.name);
  for (const n of ["Deposit", "Submission", "Confirmation", "Revocation", "Execution", "ExecutionFailure", "ThresholdChanged"]) {
    check(n + " present", names.includes(n));
  }

  console.log("\n" + (failed === 0 ? "SMOKE TEST PASSED" : "SMOKE TEST FAILED") + " — " + passed + " passed, " + failed + " failed");
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
