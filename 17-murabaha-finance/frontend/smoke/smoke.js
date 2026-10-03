/* ============================================================
   Murabaha dApp — end-to-end smoke test (Node, no npm)
   Deploys its OWN book and walks the full trade lifecycle:
   request → shariah approval → supplier purchase → delivery →
   installments → late penalty to charity → early settlement.

     1. anvil
     2. forge build
     3. BOOK=0x… node smoke/smoke.js
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
  const ABI_M = window.MURABAHA_ABI;
  const ABI_S = window.MURABAHA_STABLE_ABI;

  const provider = new ethers.JsonRpcProvider(RPC);
  const funder = new ethers.Wallet(FUNDER_KEY, provider);
  const funderAddr = funder.address;

  const shariah = ethers.Wallet.createRandom().connect(provider);
  const buyer = ethers.Wallet.createRandom().connect(provider);
  const supplier = ethers.Wallet.createRandom().connect(provider);
  const charity = ethers.Wallet.createRandom().connect(provider);
  for (const w of [shariah, buyer, supplier, charity]) {
    await (await funder.sendTransaction({ to: w.address, value: ethers.parseEther("0.5") })).wait();
  }

  console.log("== deploy murabaha ==");
  const art = (name) => JSON.parse(fs.readFileSync(path.join(__dirname, "..", "..", "out", name + ".sol", name + ".json"), "utf8"));
  const stable = await new ethers.ContractFactory(art("MockStable").abi, art("MockStable").bytecode, funder).deploy();
  await stable.waitForDeployment();
  const book = await new ethers.ContractFactory(art("MurabahaFinancing").abi, art("MurabahaFinancing").bytecode, funder)
    .deploy(await stable.getAddress(), charity.address, 500, 2, 200);
  await book.waitForDeployment();
  const BOOK = await book.getAddress();
  await (await book.grantRole(await book.SHARIAH_ROLE(), shariah.address)).wait();

  // fund the financier
  await (await stable.mint(funderAddr, ethers.parseEther("50000"))).wait();
  await (await stable.approve(BOOK, ethers.parseEther("50000"))).wait();
  // fund the buyer
  await (await stable.mint(buyer.address, ethers.parseEther("50000"))).wait();
  await (await stable.connect(buyer).approve(BOOK, ethers.parseEther("50000"))).wait();

  console.log("== request + approve + purchase + delivery ==");
  await (await book.connect(buyer).requestTrade(supplier.address, funderAddr, ethers.parseEther("10000"), ethers.parseEther("1000"), 10n, 30n * 86400n, ethers.id("inv-1"), "Solar panels, 40 kW")).wait();
  check("state Requested", Number((await book.trades(0)).status) === 0);
  await (await book.connect(shariah).approveTrade(0)).wait();
  const supplierBefore = await stable.balanceOf(supplier.address);
  await (await book.purchaseAsset(0)).wait();
  check("supplier paid cost", (await stable.balanceOf(supplier.address)) - supplierBefore === ethers.parseEther("10000"));
  await (await book.connect(buyer).confirmDelivery(0)).wait();
  check("state Delivered", Number((await book.trades(0)).status) === 3);

  console.log("== installments + late penalty to charity ==");
  const charityBefore = await stable.balanceOf(charity.address);
  await (await book.connect(buyer).payInstallment(0)).wait();
  await provider.send("evm_increaseTime", [61 * 86400]);
  await provider.send("evm_mine", []);
  await (await funder.sendTransaction({ to: funderAddr, value: 0n })).wait();
  await (await book.connect(buyer).payInstallment(0)).wait();
  check("late fee went to charity", (await stable.balanceOf(charity.address)) - charityBefore > 0n);
  const t = await book.trades(0);
  check("caught up to 3 installments", t.paidInstallments === 3n);

  console.log("== early settlement with rebate ==");
  const buyerBefore = await stable.balanceOf(buyer.address);
  await (await book.connect(buyer).settleEarly(0)).wait();
  // remaining 7 × 1,100 = 7,700; remaining markup = 700; rebate 5% = 35
  check("rebate applied", (await stable.balanceOf(buyer.address)) - (buyerBefore - ethers.parseEther("7700") + ethers.parseEther("35")) === 0n);
  check("state Settled", Number((await book.trades(0)).status) === 5);

  console.log("== pause ==");
  await (await book.pause()).wait();
  try {
    await book.connect(buyer).requestTrade(supplier.address, funderAddr, 1n, 1n, 2n, 30n * 86400n, ethers.id("x"), "paused");
    check("paused blocks requests", false, "should have reverted");
  } catch { check("paused blocks requests", true); }

  console.log("\n" + (failed === 0 ? "SMOKE TEST PASSED" : "SMOKE TEST FAILED") + " — " + passed + " passed, " + failed + " failed");
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
