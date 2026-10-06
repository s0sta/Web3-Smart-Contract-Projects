/* ============================================================
   Ataa dApp — end-to-end smoke test (Node, no npm)
   Deploys the FULL platform and walks the giving cycle:
   register → declare wealth → hawl → pay zakat 2.5% → sadaqa →
   committee allocation → DONOR TRACKING → sponsorship → governance.

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

  const donor = ethers.Wallet.createRandom().connect(provider);
  const committee1 = ethers.Wallet.createRandom().connect(provider);
  const committee2 = ethers.Wallet.createRandom().connect(provider);
  const beneficiary = ethers.Wallet.createRandom().connect(provider);
  for (const w of [donor, committee1, committee2, beneficiary]) {
    await (await funder.sendTransaction({ to: w.address, value: ethers.parseEther("0.5") })).wait();
  }

  console.log("== deploy the platform ==");
  const aeds = await new ethers.ContractFactory(art("MockStable").abi, art("MockStable").bytecode, funder).deploy();
  await aeds.waitForDeployment();
  const registry = await new ethers.ContractFactory(art("AtaaRegistry").abi, art("AtaaRegistry").bytecode, funder).deploy();
  await registry.waitForDeployment();
  const oracle = await new ethers.ContractFactory(art("AtaaOracle").abi, art("AtaaOracle").bytecode, funder).deploy(3600, 86400);
  await oracle.waitForDeployment();
  const vault = await new ethers.ContractFactory(art("AtaaVault").abi, art("AtaaVault").bytecode, funder)
    .deploy(await aeds.getAddress());
  await vault.waitForDeployment();
  const zakat = await new ethers.ContractFactory(art("AtaaZakat").abi, art("AtaaZakat").bytecode, funder)
    .deploy(await registry.getAddress(), await oracle.getAddress(), await vault.getAddress(), await aeds.getAddress());
  await zakat.waitForDeployment();
  const donations = await new ethers.ContractFactory(art("AtaaDonations").abi, art("AtaaDonations").bytecode, funder)
    .deploy(await registry.getAddress(), await vault.getAddress(), await aeds.getAddress());
  await donations.waitForDeployment();
  const allocations = await new ethers.ContractFactory(art("AtaaAllocations").abi, art("AtaaAllocations").bytecode, funder)
    .deploy(await registry.getAddress(), await vault.getAddress());
  await allocations.waitForDeployment();
  const emergency = await new ethers.ContractFactory(art("AtaaEmergency").abi, art("AtaaEmergency").bytecode, funder)
    .deploy(await registry.getAddress(), await vault.getAddress(), await aeds.getAddress());
  await emergency.waitForDeployment();
  const sponsorships = await new ethers.ContractFactory(art("AtaaSponsorships").abi, art("AtaaSponsorships").bytecode, funder)
    .deploy(await registry.getAddress(), await vault.getAddress(), await aeds.getAddress());
  await sponsorships.waitForDeployment();
  const governor = await new ethers.ContractFactory(art("AtaaGovernor").abi, art("AtaaGovernor").bytecode, funder)
    .deploy(await registry.getAddress(), await zakat.getAddress(), await vault.getAddress(), await allocations.getAddress(), await emergency.getAddress(), await sponsorships.getAddress(), await oracle.getAddress(), 0);
  await governor.waitForDeployment();

  // wiring
  await (await registry.grantRole(await registry.COMMITTEE_ROLE(), committee1.address)).wait();
  await (await registry.grantRole(await registry.COMMITTEE_ROLE(), committee2.address)).wait();
  await (await allocations.grantRole(await allocations.COMMITTEE_ROLE(), committee1.address)).wait();
  await (await allocations.grantRole(await allocations.COMMITTEE_ROLE(), committee2.address)).wait();
  await (await allocations.grantRole(await allocations.DEFAULT_ADMIN_ROLE(), await governor.getAddress())).wait();
  await (await zakat.grantRole(await zakat.COMMITTEE_ROLE(), committee1.address)).wait();
  await (await zakat.grantRole(await zakat.COMMITTEE_ROLE(), committee2.address)).wait();
  await (await vault.grantRole(await vault.ALLOCATIONS_ROLE(), await allocations.getAddress())).wait();
  await (await vault.grantRole(await vault.ALLOCATIONS_ROLE(), await donations.getAddress())).wait();
  await (await vault.grantRole(await vault.ALLOCATIONS_ROLE(), await sponsorships.getAddress())).wait();
  await (await vault.grantRole(await vault.ALLOCATIONS_ROLE(), await emergency.getAddress())).wait();
  await (await vault.setZakatModule(await zakat.getAddress())).wait();
  await (await oracle.setAssets('0x0000000000000000000000000000000000000060', '0x0000000000000000000000000000000000000051')).wait();
  await (await zakat.connect(committee1).setCashNisab(ethers.parseEther("25000"))).wait();

  async function fund(who, amount, to) {
    await (await aeds.mint(who.address, amount)).wait();
    await (await aeds.connect(who).approve(to, amount)).wait();
  }

  console.log("== zakat flow ==");
  await (await registry.connect(donor).registerDonor()).wait();
  await fund(donor, ethers.parseEther("200000"), await zakat.getAddress());
  await fund(donor, ethers.parseEther("100000"), await vault.getAddress());
  await fund(donor, ethers.parseEther("50000"), await donations.getAddress());
  await fund(donor, ethers.parseEther("50000"), await sponsorships.getAddress());
  await (await zakat.connect(donor).declareWealth(1, ethers.parseEther("100000"))).wait();
  check("hawl started (no due yet)", (await zakat.due(donor.address, 1)) === 0n);
  await provider.send("evm_increaseTime", [354 * 86400 + 3600]);
  await provider.send("evm_mine", []);
  await (await funder.sendTransaction({ to: funderAddr, value: 0n })).wait();
  check("due = 2,500 after hawl", (await zakat.due(donor.address, 1)) === ethers.parseEther("2500"));
  await (await zakat.connect(donor).payZakat(1, ethers.parseEther("2500"))).wait();
  check("zakat in vault", (await aeds.balanceOf(await vault.getAddress())) === ethers.parseEther("2500"));

  console.log("== sadaqa + tracking ==");
  await (await donations.connect(donor).donate(ethers.parseEther("5000"), 2)).wait();
  check("vault holds 7,500", (await vault.poolBalance()) === ethers.parseEther("7500"));
  const report = await vault.donorReport(donor.address);
  check("donor gave 7,500 total", report.totalGiven === ethers.parseEther("7500"));

  console.log("== committee allocation + provenance ==");
  await (await registry.registerBeneficiary(ethers.id("orphan-center"), 1, ethers.parseEther("1000"), "orphan sponsorship")).wait();
  await (await allocations.connect(committee1).propose(0, beneficiary.address, ethers.parseEther("3000"), "orphan support")).wait();
  await (await allocations.connect(committee1).vote(0, true)).wait();
  await (await allocations.connect(committee2).vote(0, true)).wait();
  check("beneficiary paid 3,000", (await aeds.balanceOf(beneficiary.address)) === ethers.parseEther("3000"));
  const report2 = await vault.donorReport(donor.address);
  check("3,000 now allocated to my donations", report2.totalAllocated === ethers.parseEther("3000"));
  const outs = await vault.outflowsOfList(0);
  check("my first contribution has outflows", outs.length >= 1);
  const out = await vault.outflows(outs[0]);
  check("outflow points to beneficiary 0", out.beneficiaryId === 0n && out.amount > 0n);

  console.log("== sponsorship + governance ==");
  await (await sponsorships.connect(donor).pledge(0, ethers.parseEther("200"))).wait();
  check("pledge active", (await sponsorships.totalMonthlyCommitted()) === ethers.parseEther("200"));
  await (await governor.recordGiving(donor.address, ethers.parseEther("7500"))).wait();
  const calldata = allocations.interface.encodeFunctionData("setBudget", [1, ethers.parseEther("50000")]);
  await (await governor.connect(donor).propose(await allocations.getAddress(), 0n, calldata, "Raise orphan budget")).wait();
  await provider.send("evm_increaseTime", [3 * 86400]);
  await provider.send("evm_mine", []);
  await (await funder.sendTransaction({ to: funderAddr, value: 0n })).wait();
  await (await governor.connect(donor).vote(0, true)).wait();
  await provider.send("evm_increaseTime", [10 * 86400]);
  await provider.send("evm_mine", []);
  await (await funder.sendTransaction({ to: funderAddr, value: 0n })).wait();
  check("proposal succeeded", Number(await governor.state(0)) === 3);
  await (await governor.execute(0)).wait();
  check("orphan budget 50,000", (await allocations.budgets(1)) === ethers.parseEther("50000"));

  console.log("\n" + (failed === 0 ? "SMOKE TEST PASSED" : "SMOKE TEST FAILED") + " — " + passed + " passed, " + failed + " failed");
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
