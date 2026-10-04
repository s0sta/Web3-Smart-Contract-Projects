/* ============================================================
   Zakat Engine dApp — end-to-end smoke test (Node, no npm)
   Deploys its OWN engine and walks the full obligation:
   declare → hawl → pay 2.5% → register recipients → propose →
   2-of-3 approvals → disbursement → ring-fence checks → pause.

     1. anvil
     2. forge build
     3. ENGINE=0x… node smoke/smoke.js
   ============================================================ */

const fs = require("fs");
const os = require("os");
const path = require("path");

const ETHER_VERSION = "6.13.4";
const ETHER_CDN = `https://cdn.jsdelivr.net/npm/ethers@${ETHER_VERSION}/dist/ethers.umd.min.js`;

const RPC = process.env.RPC || "http://127.0.0.1:8545";
const FUNDER_KEY = process.env.FUNDER_KEY || "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";

async function loadEthers() {
  const tmp = path.join(os.tmpdir(), `ethers-${ETHER_VERSION}.umd.min.js`);
  if (!fs.existsSync(tmp)) {
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
  const ethers = await loadEthers();
  global.window = {};
  require(path.join(__dirname, "..", "js", "abi.js"));
  const ABI_E = window.ZAKAT_ENGINE_ABI;
  const ABI_R = window.ZAKAT_REGISTRY_ABI;
  const ABI_S = window.ZAKAT_STABLE_ABI;

  const provider = new ethers.JsonRpcProvider(RPC);
  const funder = new ethers.Wallet(FUNDER_KEY, provider);
  const funderAddr = funder.address;

  const committee1 = ethers.Wallet.createRandom().connect(provider);
  const committee2 = ethers.Wallet.createRandom().connect(provider);
  const payer = ethers.Wallet.createRandom().connect(provider);
  const recipient = ethers.Wallet.createRandom().connect(provider);
  for (const w of [committee1, committee2, payer, recipient]) {
    await (await funder.sendTransaction({ to: w.address, value: ethers.parseEther("0.5") })).wait();
  }

  console.log("== deploy zakat ==");
  const art = (name) => JSON.parse(fs.readFileSync(path.join(__dirname, "..", "..", "out", name + ".sol", name + ".json"), "utf8"));
  const stable = await new ethers.ContractFactory(art("MockStable").abi, art("MockStable").bytecode, funder).deploy();
  await stable.waitForDeployment();
  const registry = await new ethers.ContractFactory(art("AsnafRegistry").abi, art("AsnafRegistry").bytecode, funder)
    .deploy([committee1.address, committee2.address]);
  await registry.waitForDeployment();
  const engine = await new ethers.ContractFactory(art("ZakatEngine").abi, art("ZakatEngine").bytecode, funder)
    .deploy(await registry.getAddress(), await stable.getAddress(), ethers.parseEther("4000"));
  await engine.waitForDeployment();
  const ENG = await engine.getAddress();
  await (await engine.grantRole(await engine.COMMITTEE_ROLE(), committee1.address)).wait();
  await (await engine.grantRole(await engine.COMMITTEE_ROLE(), committee2.address)).wait();
  await (await registry.setEngine(ENG)).wait();
  await (await registry.setAllocation(0, 6000)).wait();
  await (await registry.setAllocation(1, 4000)).wait();

  console.log("== declare + hawl + pay ==");
  await (await stable.mint(payer.address, ethers.parseEther("200000"))).wait();
  await (await stable.connect(payer).approve(ENG, ethers.parseEther("200000"))).wait();
  await (await engine.connect(payer).declareWealth(ethers.parseEther("100000"))).wait();
  check("no zakat before hawl", (await engine.zakatDue(payer.address)) === 0n);
  await provider.send("evm_increaseTime", [354 * 86400 + 100]);
  await provider.send("evm_mine", []);
  await (await funder.sendTransaction({ to: funderAddr, value: 0n })).wait();
  check("2.5% due after hawl", (await engine.zakatDue(payer.address)) === ethers.parseEther("2500"));
  await (await engine.connect(payer).payZakat()).wait();
  check("fund ring-fenced", (await engine.zakatFund()) === ethers.parseEther("2500"));

  console.log("== recipients + disbursement ==");
  await (await registry.registerRecipient(recipient.address, 0, ethers.id("proof-1"))).wait();
  const prop = await (await engine.proposeDisbursement(0n, ethers.parseEther("1000"))).wait();
  const before = await stable.balanceOf(recipient.address);
  await (await engine.connect(committee1).voteDisbursement(0, true)).wait();
  check("one approval not enough", (await stable.balanceOf(recipient.address)) === before);
  await (await engine.connect(committee2).voteDisbursement(0, true)).wait();
  check("paid after 2 approvals", (await stable.balanceOf(recipient.address)) - before === ethers.parseEther("1000"));
  check("fund decreased", (await engine.zakatFund()) === ethers.parseEther("1500"));

  console.log("== ring-fence: committee cannot divert ==");
  try {
    await engine.connect(committee1).proposeDisbursement(0n, ethers.parseEther("5000")); // exceeds fund
    check("oversized proposal blocked", false, "should have reverted");
  } catch { check("oversized proposal blocked", true); }

  console.log("== pause ==");
  await (await engine.pause()).wait();
  try {
    await engine.connect(payer).declareWealth(ethers.parseEther("1"));
    check("paused blocks declarations", false, "should have reverted");
  } catch { check("paused blocks declarations", true); }

  console.log("\n" + (failed === 0 ? "SMOKE TEST PASSED" : "SMOKE TEST FAILED") + " — " + passed + " passed, " + failed + " failed");
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
