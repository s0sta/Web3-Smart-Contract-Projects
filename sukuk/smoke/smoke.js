/* ============================================================
   Sukuk Vault dApp — end-to-end smoke test (Node, no npm)
   Deploys its OWN sukuk and walks the full lifecycle:
   issuance → purchase → income → Shariah approval → distribute →
   claim → maturity → asset sale → redemption → freeze.

     1. anvil
     2. forge build
     3. VAULT=0x… node smoke/smoke.js
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
  const ABI_V = window.SUKUK_VAULT_ABI;
  const ABI_S = window.SUKUK_STABLE_ABI;

  const provider = new ethers.JsonRpcProvider(RPC);
  const funder = new ethers.Wallet(FUNDER_KEY, provider);
  const funderAddr = funder.address;

  const shariah = ethers.Wallet.createRandom().connect(provider);
  const investor = ethers.Wallet.createRandom().connect(provider);
  for (const w of [shariah, investor]) {
    await (await funder.sendTransaction({ to: w.address, value: ethers.parseEther("0.5") })).wait();
  }

  console.log("== deploy sukuk ==");
  const art = (name) => JSON.parse(fs.readFileSync(path.join(__dirname, "..", "..", "out", name + ".sol", name + ".json"), "utf8"));
  const stable = await new ethers.ContractFactory(art("MockStable").abi, art("MockStable").bytecode, funder).deploy();
  await stable.waitForDeployment();
  const vault = await new ethers.ContractFactory(art("SukukVault").abi, art("SukukVault").bytecode, funder)
    .deploy(await stable.getAddress(), 1000);
  await vault.waitForDeployment();
  const VAL = await vault.getAddress();
  await (await vault.grantRole(await vault.SHARIAH_ROLE(), shariah.address)).wait();

  const chainNow = Number((await provider.getBlock("latest")).timestamp);
  await (await vault.issueSeries("Green Ijarah Sukuk - Series 1", ethers.parseEther("100"), 1000, chainNow + 86400, "Solar rooftop array, Al Quoz - 1.2 MWp", 800)).wait();

  console.log("== purchase ==");
  await (await stable.mint(investor.address, ethers.parseEther("50000"))).wait();
  await (await stable.connect(investor).approve(VAL, ethers.parseEther("40000"))).wait();
  await (await vault.connect(investor).purchase(0, 400n)).wait();
  check("investor holds 400", (await vault.certificates(0, investor.address)) === 400n);
  check("vault collected 40k", (await stable.balanceOf(VAL)) === ethers.parseEther("40000"));

  console.log("== ijarah income + Shariah gate ==");
  await (await stable.mint(funderAddr, ethers.parseEther("5000"))).wait();
  await (await stable.approve(VAL, ethers.parseEther("5000"))).wait();
  await (await vault.recordIncome(0, ethers.parseEther("5000"))).wait();
  check("income pending", (await vault.pendingApproval(0)) === ethers.parseEther("5000"));
  await (await vault.connect(shariah).approveIncome(0)).wait();
  check("10% smoothing reserve", (await vault.profitReserve(0)) === ethers.parseEther("500"));
  check("pool 4500", (await vault.distributablePool(0)) === ethers.parseEther("4500"));

  console.log("== distribute + claim ==");
  await (await vault.distribute(0)).wait();
  check("claimable = 400 × 4.5", (await vault.claimable(0, investor.address)) === ethers.parseEther("1800"));
  const before = await stable.balanceOf(investor.address);
  await (await vault.connect(investor).claim(0)).wait();
  check("claimed 1800", (await stable.balanceOf(investor.address)) - before === ethers.parseEther("1800"));

  console.log("== maturity + redemption ==");
  await provider.send("evm_increaseTime", [2 * 86400]);
  await provider.send("evm_mine", []);
  await (await funder.sendTransaction({ to: funderAddr, value: 0n })).wait();
  // top up the vault to cover the face-value proceeds (the manager's sale proceeds)
  await (await stable.mint(funderAddr, ethers.parseEther("40000"))).wait();
  await (await vault.sellUnderlying(0, ethers.parseEther("40000"))).wait();
  check("redemption pool funded", (await vault.redemptionPool(0)) === ethers.parseEther("40000"));
  const before2 = await stable.balanceOf(investor.address);
  await (await vault.connect(investor).redeem(0, 400n)).wait();
  check("redeemed 40k at face", (await stable.balanceOf(investor.address)) - before2 === ethers.parseEther("40000"));
  check("certificates burned", (await vault.certificates(0, investor.address)) === 0n);

  console.log("== freeze ==");
  await (await vault.setSeriesFrozen(0, true)).wait();
  try {
    await (await vault.issueSeries("Frozen test", 1n, 1, chainNow + 999999, "x", 0)).wait();
  } catch { /* issuance is not frozen — only purchases; keep going */ }
  const before3 = await stable.balanceOf(investor.address);
  await (await stable.mint(investor.address, ethers.parseEther("10000"))).wait();
  await (await stable.connect(investor).approve(VAL, ethers.parseEther("10000"))).wait();
  try {
    await vault.connect(investor).purchase(0, 1n);
    check("frozen blocks purchase", false, "should have reverted");
  } catch { check("frozen blocks purchase", true); }

  console.log("\n" + (failed === 0 ? "SMOKE TEST PASSED" : "SMOKE TEST FAILED") + " — " + passed + " passed, " + failed + " failed");
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
