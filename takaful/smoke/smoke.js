/* ============================================================
   Takaful dApp — end-to-end smoke test (Node, no npm)
   Deploys its OWN pool and walks the full mutual lifecycle:
   join → claim → committee votes → payout → qard hasan →
   surplus → pause.

     1. anvil
     2. forge build
     3. POOL=0x… node smoke/smoke.js
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
  const ABI_P = window.TAKAFUL_POOL_ABI;
  const ABI_S = window.TAKAFUL_STABLE_ABI;

  const provider = new ethers.JsonRpcProvider(RPC);
  const funder = new ethers.Wallet(FUNDER_KEY, provider);
  const funderAddr = funder.address;

  const assessor1 = ethers.Wallet.createRandom().connect(provider);
  const assessor2 = ethers.Wallet.createRandom().connect(provider);
  const alice = ethers.Wallet.createRandom().connect(provider);
  const bob = ethers.Wallet.createRandom().connect(provider);
  for (const w of [assessor1, assessor2, alice, bob]) {
    await (await funder.sendTransaction({ to: w.address, value: ethers.parseEther("0.5") })).wait();
  }

  console.log("== deploy takaful ==");
  const art = (name) => JSON.parse(fs.readFileSync(path.join(__dirname, "..", "..", "out", name + ".sol", name + ".json"), "utf8"));
  const stable = await new ethers.ContractFactory(art("MockStable").abi, art("MockStable").bytecode, funder).deploy();
  await stable.waitForDeployment();
  const pool = await new ethers.ContractFactory(art("TakafulPool").abi, art("TakafulPool").bytecode, funder)
    .deploy(await stable.getAddress());
  await pool.waitForDeployment();
  const POOL = await pool.getAddress();
  await (await pool.grantRole(await pool.ASSESSOR_ROLE(), assessor1.address)).wait();
  await (await pool.grantRole(await pool.ASSESSOR_ROLE(), assessor2.address)).wait();
  await (await pool.setAssessorCount(3)).wait();
  await (await pool.registerPool("Motor", ethers.parseEther("500"), 1000, ethers.parseEther("2000"), 90 * 86400, 30 * 86400)).wait();

  async function fund(who, amount) {
    await (await stable.mint(who.address, amount)).wait();
    await (await stable.connect(who).approve(POOL, amount)).wait();
  }

  console.log("== join (tabarru) ==");
  await fund(alice, ethers.parseEther("500"));
  await (await pool.connect(alice).joinPool(0)).wait();
  check("policy issued", (await pool.policies(0)).holder.toLowerCase() === alice.address.toLowerCase());
  check("10% wakalah withheld", (await pool.totalWakalahFees()) === ethers.parseEther("50"));

  console.log("== claim + committee ==");
  await (await pool.connect(alice).fileClaim(0, ethers.parseEther("300"), "minor collision")).wait();
  check("one approval not enough", (await stable.balanceOf(alice.address)) < ethers.parseEther("100000"));
  await (await pool.connect(assessor1).voteClaim(0, true)).wait();
  const before = await stable.balanceOf(alice.address);
  await (await pool.connect(assessor2).voteClaim(0, true)).wait();
  check("paid after 2 approvals", (await stable.balanceOf(alice.address)) - before === ethers.parseEther("300"));
  check("claim marked paid", (await pool.claims(0)).decided === true);

  console.log("== qard hasan bridge ==");
  await fund(alice, ethers.parseEther("0"));
  await (await pool.connect(alice).fileClaim(0, ethers.parseEther("1700"), "total loss")).wait(); // limit 2000-300
  await (await pool.connect(assessor1).voteClaim(1, true)).wait();
  try {
    await pool.connect(assessor2).voteClaim(1, true);
    check("bridge blocks unfunded shortfall", false, "should have reverted");
  } catch { check("bridge blocks unfunded shortfall", true); }
  await fund(funder, ethers.parseEther("2000"));
  await (await pool.fundQardHasan(ethers.parseEther("2000"))).wait();
  const before2 = await stable.balanceOf(alice.address);
  await (await pool.connect(assessor2).voteClaim(1, true)).wait();
  check("bridge funded the payout", (await stable.balanceOf(alice.address)) - before2 === ethers.parseEther("1700"));

  console.log("== surplus (no-claim benefit) ==");
  await fund(bob, ethers.parseEther("500"));
  await (await pool.connect(bob).joinPool(0)).wait();
  // fund above the reserve floor so a surplus exists
  await fund(funder, ethers.parseEther("10000"));
  await (await pool.recordInvestmentIncome(ethers.parseEther("10000"))).wait();
  const bobBefore = await stable.balanceOf(bob.address);
  await (await pool.distributeSurplus(0, [bob.address])).wait();
  check("non-claimer bob received surplus", (await stable.balanceOf(bob.address)) > bobBefore);

  console.log("== pause ==");
  await (await pool.pause()).wait();
  try {
    await pool.connect(alice).joinPool(0);
    check("paused blocks joining", false, "should have reverted");
  } catch { check("paused blocks joining", true); }

  console.log("\n" + (failed === 0 ? "SMOKE TEST PASSED" : "SMOKE TEST FAILED") + " — " + passed + " passed, " + failed + " failed");
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
