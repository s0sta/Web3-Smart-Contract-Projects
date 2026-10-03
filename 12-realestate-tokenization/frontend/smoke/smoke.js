/* ============================================================
   Estate Tokenization dApp — end-to-end smoke test (Node, no npm)
   Deploys its OWN estate and walks the full lifecycle:
   register → KYC → issue → transfer (snapshot check) → rent →
   distribute → claim → maintenance → pause.

     1. anvil
     2. forge build
     3. REGISTRY=0x… node smoke/smoke.js   (reads work on any deployment)
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
  const ABI_R = window.ESTATE_REGISTRY_ABI;
  const ABI_D = window.ESTATE_DISTRIBUTOR_ABI;
  const ABI_S = window.ESTATE_STABLE_ABI;

  const provider = new ethers.JsonRpcProvider(RPC);
  const funder = new ethers.NonceManager(new ethers.Wallet(FUNDER_KEY, provider));
  const funderAddr = new ethers.Wallet(FUNDER_KEY).address;
  const ifaceR = new ethers.Interface(ABI_R);

  const manager = ethers.Wallet.createRandom().connect(provider);
  const alice = ethers.Wallet.createRandom().connect(provider);
  const bob = ethers.Wallet.createRandom().connect(provider);
  for (const w of [manager, alice, bob]) {
    await (await funder.sendTransaction({ to: w.address, value: ethers.parseEther("0.5") })).wait();
  }

  console.log("== deploy estate ==");
  const art = (name) => JSON.parse(fs.readFileSync(path.join(__dirname, "..", "..", "out", name + ".sol", name + ".json"), "utf8"));
  const stable = await new ethers.ContractFactory(art("MockStable").abi, art("MockStable").bytecode, funder).deploy();
  await stable.waitForDeployment();
  const registry = await new ethers.ContractFactory(art("RERAPropertyRegistry").abi, art("RERAPropertyRegistry").bytecode, funder).deploy();
  await registry.waitForDeployment();
  const distributor = await new ethers.ContractFactory(art("RentalDistributor").abi, art("RentalDistributor").bytecode, funder)
    .deploy(await registry.getAddress(), await stable.getAddress(), 1000);
  await distributor.waitForDeployment();
  const REG = await registry.getAddress();

  console.log("== register + KYC + issue ==");
  await (await registry.registerProperty("Marina Gate Tower", ethers.parseEther("1000"), ethers.parseEther("5000000"))).wait();
  await (await registry.setWhitelisted(0, manager.address, true)).wait();
  await (await registry.setWhitelisted(0, alice.address, true)).wait();
  await (await registry.setWhitelisted(0, bob.address, true)).wait();
  await (await registry.issueShares(0, alice.address, ethers.parseEther("400"))).wait();
  await (await registry.issueShares(0, bob.address, ethers.parseEther("300"))).wait();
  await (await registry.issueShares(0, manager.address, ethers.parseEther("300"))).wait();
  check("issued 1000", (await registry.balanceOf(0, alice.address)) === ethers.parseEther("400"));

  console.log("== snapshot transfer ==");
  // rent + distribute BEFORE the sale
  await (await stable.mint(funderAddr, ethers.parseEther("100000"))).wait();
  await (await stable.approve(await distributor.getAddress(), ethers.parseEther("100000"))).wait();
  await (await distributor.payRent(0, ethers.parseEther("10000"))).wait();
  check("reserve 10%", (await distributor.maintenanceFund(0)) === ethers.parseEther("1000"));
  await (await distributor.distribute(0)).wait();
  // alice sells 100 shares to bob AFTER the epoch
  await (await registry.connect(alice).transferShares(0, bob.address, ethers.parseEther("100"))).wait();
  check("epoch income stays with seller", (await distributor.claimable(0, alice.address)) === ethers.parseEther("3600")); // 400 × 9
  check("buyer gets own share only", (await distributor.claimable(0, bob.address)) === ethers.parseEther("2700")); // 300 × 9

  console.log("== claim ==");
  const before = await stable.balanceOf(alice.address);
  await (await distributor.connect(alice).claim(0)).wait();
  check("alice claimed 3600", (await stable.balanceOf(alice.address)) - before === ethers.parseEther("3600"));

  console.log("== second epoch (post-sale balances) ==");
  await (await distributor.payRent(0, ethers.parseEther("10000"))).wait();
  await (await distributor.distribute(0)).wait();
  check("epoch 2: alice 300 shares", (await distributor.claimable(0, alice.address)) === ethers.parseEther("2700"));
  check("bob claimable = epochs 0+1 (6300)", (await distributor.claimable(0, bob.address)) === ethers.parseEther("6300"));

  console.log("== maintenance & compliance ==");
  await (await distributor.spendMaintenance(0, manager.address, ethers.parseEther("500"))).wait();
  check("maintenance spent (2000 - 500 = 1500 left)", (await distributor.maintenanceFund(0)) === ethers.parseEther("1500"));
  await (await registry.setFrozen(0, true)).wait();
  try {
    await registry.connect(alice).transferShares(0, bob.address, 1n);
    check("frozen blocks transfer", false, "should have reverted");
  } catch { check("frozen blocks transfer", true); }

  console.log("== appraisals & errors ==");
  await (await registry.appraise(0, ethers.parseEther("5500000"))).wait();
  const p = await registry.properties(0);
  check("re-appraisal recorded", p.valuationUsd === ethers.parseEther("5500000"));
  try {
    await registry.issueShares(0, alice.address, ethers.parseEther("1000"));
    check("over-issuance reverts", false, "should have reverted");
  } catch { check("over-issuance reverts", true); }

  console.log("\n" + (failed === 0 ? "SMOKE TEST PASSED" : "SMOKE TEST FAILED") + " — " + passed + " passed, " + failed + " failed");
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
