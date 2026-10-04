/* ============================================================
   Silsila dApp — end-to-end smoke test (Node, no npm)
   Deploys the FULL trade network and walks the goods cycle:
   register → order → accept → ship → milestones → deliver →
   fund → release payments → insure → claim → governance.

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

  const buyer = ethers.Wallet.createRandom().connect(provider);
  const supplier = ethers.Wallet.createRandom().connect(provider);
  const carrier = ethers.Wallet.createRandom().connect(provider);
  const auditor = ethers.Wallet.createRandom().connect(provider);
  const adjuster = ethers.Wallet.createRandom().connect(provider);
  for (const w of [buyer, supplier, carrier, auditor, adjuster]) {
    await (await funder.sendTransaction({ to: w.address, value: ethers.parseEther("0.5") })).wait();
  }

  console.log("== deploy the network ==");
  const aeds = await new ethers.ContractFactory(art("MockStable").abi, art("MockStable").bytecode, funder).deploy();
  await aeds.waitForDeployment();
  const registry = await new ethers.ContractFactory(art("SilsilaRegistry").abi, art("SilsilaRegistry").bytecode, funder).deploy();
  await registry.waitForDeployment();
  const compliance = await new ethers.ContractFactory(art("SilsilaCompliance").abi, art("SilsilaCompliance").bytecode, funder)
    .deploy(await registry.getAddress());
  await compliance.waitForDeployment();
  const orders = await new ethers.ContractFactory(art("SilsilaOrders").abi, art("SilsilaOrders").bytecode, funder)
    .deploy(await registry.getAddress(), await compliance.getAddress());
  await orders.waitForDeployment();
  const shipments = await new ethers.ContractFactory(art("SilsilaShipments").abi, art("SilsilaShipments").bytecode, funder)
    .deploy(await registry.getAddress(), await orders.getAddress());
  await shipments.waitForDeployment();
  const quality = await new ethers.ContractFactory(art("SilsilaQuality").abi, art("SilsilaQuality").bytecode, funder)
    .deploy(await registry.getAddress(), await shipments.getAddress(), await orders.getAddress());
  await quality.waitForDeployment();
  const treasury = await new ethers.ContractFactory(art("SilsilaTreasury").abi, art("SilsilaTreasury").bytecode, funder)
    .deploy(await aeds.getAddress(), 2000);
  await treasury.waitForDeployment();
  const payments = await new ethers.ContractFactory(art("SilsilaPayments").abi, art("SilsilaPayments").bytecode, funder)
    .deploy(await registry.getAddress(), await orders.getAddress(), await shipments.getAddress(), await treasury.getAddress(), await aeds.getAddress());
  await payments.waitForDeployment();
  const cargo = await new ethers.ContractFactory(art("SilsilaCargoInsurance").abi, art("SilsilaCargoInsurance").bytecode, funder)
    .deploy(await registry.getAddress(), await orders.getAddress(), await shipments.getAddress(), await aeds.getAddress());
  await cargo.waitForDeployment();
  const reputation = await new ethers.ContractFactory(art("SilsilaReputation").abi, art("SilsilaReputation").bytecode, funder)
    .deploy(await registry.getAddress(), await shipments.getAddress(), await quality.getAddress());
  await reputation.waitForDeployment();
  const oracle = await new ethers.ContractFactory(art("SilsilaOracle").abi, art("SilsilaOracle").bytecode, funder)
    .deploy(3600, 86400);
  await oracle.waitForDeployment();
  const governor = await new ethers.ContractFactory(art("SilsilaGovernor").abi, art("SilsilaGovernor").bytecode, funder)
    .deploy(await registry.getAddress(), await compliance.getAddress(), await orders.getAddress(), await shipments.getAddress(), await quality.getAddress(), await payments.getAddress(), await cargo.getAddress(), await reputation.getAddress(), await treasury.getAddress(), await oracle.getAddress(), 300);
  await governor.waitForDeployment();

  // wiring
  await (await compliance.setRegionAllowed(784, true)).wait();
  await (await cargo.grantRole(await cargo.ADJUSTER_ROLE(), adjuster.address)).wait();
  await (await payments.grantRole(await payments.OPERATOR_ROLE(), await governor.getAddress())).wait();
  await (await aeds.mint(await cargo.getAddress(), ethers.parseEther("500000"))).wait();

  async function fund(who, amount, to) {
    await (await aeds.mint(who.address, amount)).wait();
    await (await aeds.connect(who).approve(to, amount)).wait();
  }

  console.log("== entities + order ==");
  await (await registry.connect(buyer).register(1, 784)).wait();
  await (await registry.connect(supplier).register(2, 784)).wait();
  await (await registry.connect(carrier).register(3, 784)).wait();
  await (await registry.connect(auditor).register(4, 784)).wait();
  check("4 entities registered", Number(await registry.entityCount()) === 4);
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 30 * 86400);
  await (await orders.connect(buyer).createOrder(supplier.address, 100n, ethers.parseEther("100"), deadline, 784, ethers.id("item"), false, ethers.ZeroHash)).wait();
  await (await orders.connect(supplier).accept(0)).wait();
  check("order accepted", Number((await orders.orders(0)).status) === 1);

  console.log("== shipment journey ==");
  await (await shipments.connect(buyer).createShipment(0, carrier.address)).wait();
  await (await shipments.connect(carrier).updateMilestone(0, 2, ethers.id("packed"))).wait();
  await (await shipments.connect(carrier).updateMilestone(0, 3, ethers.id("transit"))).wait();
  await (await shipments.connect(carrier).updateMilestone(0, 4, ethers.id("customs"))).wait();
  await (await shipments.connect(carrier).deliver(0, ethers.id("pod"))).wait();
  check("delivered with POD", Number((await shipments.shipments(0)).milestone) === 5);

  console.log("== payments ==");
  await fund(buyer, ethers.parseEther("100000"), await payments.getAddress());
  await (await payments.connect(buyer).fund(0, ethers.parseEther("10000"))).wait();
  check("escrow funded 10,000", (await aeds.balanceOf(await payments.getAddress())) === ethers.parseEther("10000"));
  const supplierBefore = await aeds.balanceOf(supplier.address);
  await (await payments.release(0, 5)).wait(); // delivery milestone → 70% + carrier + no penalty
  check("supplier paid ~6,965", (await aeds.balanceOf(supplier.address)) - supplierBefore === ethers.parseEther("6965"));

  console.log("== cargo insurance ==");
  await fund(buyer, ethers.parseEther("10000"), await cargo.getAddress());
  await (await cargo.connect(buyer).insure(0, ethers.parseEther("10000"))).wait();
  await (await cargo.connect(buyer).fileClaim(0, ethers.parseEther("4000"), "cargo damaged")).wait();
  await (await cargo.connect(adjuster).voteClaim(0, true)).wait();
  const before = await aeds.balanceOf(buyer.address);
  await (await cargo.connect(funder).voteClaim(0, true)).wait();
  check("claim paid 4,000", (await aeds.balanceOf(buyer.address)) - before === ethers.parseEther("4000"));

  console.log("== reputation + governance ==");
  await (await reputation.recordDelivery(carrier.address, true)).wait();
  check("carrier score > 500", (await reputation.scoreOf(carrier.address)) > 500n);
  const calldata = payments.interface.encodeFunctionData("setFees", [60, 500, 300]);
  await (await governor.connect(funder).propose(await payments.getAddress(), 0n, calldata, "Raise platform fee to 0.6%")).wait();
  await provider.send("evm_increaseTime", [3 * 86400]);
  await provider.send("evm_mine", []);
  await (await funder.sendTransaction({ to: funderAddr, value: 0n })).wait();
  await (await governor.connect(carrier).vote(0, true)).wait();
  await provider.send("evm_increaseTime", [10 * 86400]);
  await provider.send("evm_mine", []);
  await (await funder.sendTransaction({ to: funderAddr, value: 0n })).wait();
  check("proposal succeeded", Number(await governor.state(0)) === 3);
  await (await governor.execute(0)).wait();
  check("platform fee 0.6%", (await payments.platformFeeBps()) === 60n);

  console.log("\n" + (failed === 0 ? "SMOKE TEST PASSED" : "SMOKE TEST FAILED") + " — " + passed + " passed, " + failed + " failed");
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
