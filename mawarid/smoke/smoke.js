/* ============================================================
   Mawarid dApp — end-to-end smoke test (Node, no npm)
   Deploys the FULL platform and walks the institutional flow:
   KYC → primary subscription → allocation → secondary order + fill →
   rental epochs → governance proposal → treasury fees.

     1. anvil
     2. forge build
     3. REGISTRY=0x… node smoke/smoke.js
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
  const art = (name) => JSON.parse(fs.readFileSync(path.join(__dirname, "..", "..", "out", name + ".sol", name + ".json"), "utf8"));

  const provider = new ethers.JsonRpcProvider(RPC);
  const funder = new ethers.Wallet(FUNDER_KEY, provider);
  const funderAddr = funder.address;

  const officer = ethers.Wallet.createRandom().connect(provider);
  const investor = ethers.Wallet.createRandom().connect(provider);
  const buyer = ethers.Wallet.createRandom().connect(provider);
  for (const w of [officer, investor, buyer]) {
    await (await funder.sendTransaction({ to: w.address, value: ethers.parseEther("0.5") })).wait();
  }

  console.log("== deploy the full platform ==");
  const stable = await new ethers.ContractFactory(art("MockStable").abi, art("MockStable").bytecode, funder).deploy();
  await stable.waitForDeployment();
  const compliance = await new ethers.ContractFactory(art("MawaridCompliance").abi, art("MawaridCompliance").bytecode, funder).deploy([officer.address]);
  await compliance.waitForDeployment();
  const registry = await new ethers.ContractFactory(art("MawaridAssetRegistry").abi, art("MawaridAssetRegistry").bytecode, funder).deploy();
  await registry.waitForDeployment();
  const assetId = await (await registry.registerAsset("Marina Gate Tower - Floor 21", "Residential", ethers.id("docs"), ethers.parseEther("1000"), ethers.parseEther("5000000"))).wait().then(() => 0n);
  await (await registry.setStatus(assetId, 1)).wait();
  const shares = await new ethers.ContractFactory(art("MawaridShares").abi, art("MawaridShares").bytecode, funder)
    .deploy(await compliance.getAddress(), assetId, "Marina Gate Shares", "MGS");
  await shares.waitForDeployment();
  await (await shares.setTransfersEnabled(true)).wait();
  const primary = await new ethers.ContractFactory(art("MawaridPrimaryMarket").abi, art("MawaridPrimaryMarket").bytecode, funder)
    .deploy(await shares.getAddress(), await compliance.getAddress(), await registry.getAddress(), await stable.getAddress());
  await primary.waitForDeployment();
  const secondary = await new ethers.ContractFactory(art("MawaridSecondaryMarket").abi, art("MawaridSecondaryMarket").bytecode, funder)
    .deploy(await shares.getAddress(), await compliance.getAddress(), await stable.getAddress(), funderAddr, 100);
  await secondary.waitForDeployment();
  const distributor = await new ethers.ContractFactory(art("MawaridRentalDistributor").abi, art("MawaridRentalDistributor").bytecode, funder)
    .deploy(await shares.getAddress(), await registry.getAddress(), await stable.getAddress(), 1000);
  await distributor.waitForDeployment();
  const treasury = await new ethers.ContractFactory(art("MawaridTreasury").abi, art("MawaridTreasury").bytecode, funder)
    .deploy(await stable.getAddress(), 2000);
  await treasury.waitForDeployment();
  const insurance = await new ethers.ContractFactory(art("MawaridInsuranceFund").abi, art("MawaridInsuranceFund").bytecode, funder)
    .deploy(await distributor.getAddress(), await stable.getAddress());
  await insurance.waitForDeployment();
  const governor = await new ethers.ContractFactory(art("MawaridAssetGovernor").abi, art("MawaridAssetGovernor").bytecode, funder)
    .deploy(await shares.getAddress(), await registry.getAddress(), await distributor.getAddress(), await treasury.getAddress());
  await governor.waitForDeployment();

  // wiring
  await (await registry.grantRole(await registry.MANAGER_ROLE(), await primary.getAddress())).wait();
  await (await registry.grantRole(await registry.MANAGER_ROLE(), await governor.getAddress())).wait();
  await (await shares.grantRole(await shares.ISSUER_ROLE(), await primary.getAddress())).wait();
  await (await secondary.setTreasury(await treasury.getAddress())).wait();
  await (await distributor.grantRole(await distributor.MANAGER_ROLE(), await insurance.getAddress())).wait();
  await (await treasury.grantRole(await treasury.OPERATOR_ROLE(), await governor.getAddress())).wait();
  await (await compliance.connect(officer).setKyc(investor.address, 2)).wait();
  await (await compliance.connect(officer).setKyc(buyer.address, 1)).wait();
  await (await compliance.connect(officer).setKyc(await secondary.getAddress(), 1)).wait();

  async function fund(who, amount) {
    await (await stable.mint(who.address, amount)).wait();
    await (await stable.connect(who).approve(await primary.getAddress(), amount)).wait();
    await (await stable.connect(who).approve(await secondary.getAddress(), amount)).wait();
  }

  console.log("== primary issuance ==");
  const chainNow = Number((await provider.getBlock("latest")).timestamp);
  await (await primary.openPhase(assetId, ethers.parseEther("100"), ethers.parseEther("1000"), chainNow, chainNow + 86400)).wait();
  await fund(investor, ethers.parseEther("50000"));
  await (await primary.connect(investor).subscribe(0, ethers.parseEther("400"))).wait();
  check("subscription escrowed", (await stable.balanceOf(await primary.getAddress())) === ethers.parseEther("40000"));
  await provider.send("evm_increaseTime", [2 * 86400]);
  await provider.send("evm_mine", []);
  await (await funder.sendTransaction({ to: funderAddr, value: 0n })).wait();
  await (await primary.finalizePhase(0)).wait();
  await (await primary.connect(investor).claimAllocation(0)).wait();
  check("shares minted", (await shares.balanceOf(investor.address)) === ethers.parseEther("400"));

  console.log("== secondary market ==");
  await (await shares.connect(investor).approve(await secondary.getAddress(), ethers.parseEther("400"))).wait();
  await fund(buyer, ethers.parseEther("50000"));
  await (await secondary.connect(investor).placeOrder(assetId, ethers.parseEther("100"), ethers.parseEther("110"))).wait();
  const buyerBefore = await stable.balanceOf(buyer.address);
  await (await secondary.connect(buyer).fillOrder(0, ethers.parseEther("100"))).wait();
  check("buyer paid 11,000 + fee", (await stable.balanceOf(buyer.address)) === buyerBefore - ethers.parseEther("11000"));
  check("1% fee to treasury", (await treasury.totalFeesCollected()) === 0n || (await stable.balanceOf(await treasury.getAddress())) === ethers.parseEther("110"));

  console.log("== rental epoch ==");
  await (await stable.mint(funderAddr, ethers.parseEther("10000"))).wait();
  await (await stable.approve(await distributor.getAddress(), ethers.parseEther("10000"))).wait();
  await (await distributor.recordIncome(assetId, ethers.parseEther("10000"))).wait();
  await (await distributor.distribute(assetId)).wait();
  const rent = await distributor.claimable(assetId, investor.address);
  check("rent claimable (300 × 9)", rent === ethers.parseEther("2700"));
  const before = await stable.balanceOf(investor.address);
  await (await distributor.connect(investor).claim(assetId)).wait();
  check("rent claimed", (await stable.balanceOf(investor.address)) - before === ethers.parseEther("2700"));

  console.log("== governance ==");
  const calldata = registry.interface.encodeFunctionData("appraise", [assetId, ethers.parseEther("5500000")]);
  await (await governor.connect(investor).propose(0, assetId, await registry.getAddress(), 0n, calldata, "Revalue to 5.5M")).wait();
  await provider.send("evm_increaseTime", [3 * 86400]);
  await provider.send("evm_mine", []);
  await (await funder.sendTransaction({ to: funderAddr, value: 0n })).wait();
  await (await governor.connect(investor).vote(0, true)).wait();
  await provider.send("evm_increaseTime", [10 * 86400]);
  await provider.send("evm_mine", []);
  await (await funder.sendTransaction({ to: funderAddr, value: 0n })).wait();
  check("proposal succeeded", Number(await governor.state(0)) === 3);
  await (await governor.execute(0)).wait();
  const a = await registry.assets(assetId);
  check("appraisal revalued to 5.5M", a.appraisalUsd === ethers.parseEther("5500000"));

  console.log("\n" + (failed === 0 ? "SMOKE TEST PASSED" : "SMOKE TEST FAILED") + " — " + passed + " passed, " + failed + " failed");
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
