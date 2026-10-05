/* ============================================================
   Daman dApp — end-to-end smoke test (Node, no npm)
   Deploys the FULL mutual and walks the insurance cycle:
   register → buy policy → file claim → 2-of-3 approval → payout →
   parametric cover → oracle trigger → auto payout → governance.

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

  const holder = ethers.Wallet.createRandom().connect(provider);
  const adjuster1 = ethers.Wallet.createRandom().connect(provider);
  const adjuster2 = ethers.Wallet.createRandom().connect(provider);
  for (const w of [holder, adjuster1, adjuster2]) {
    await (await funder.sendTransaction({ to: w.address, value: ethers.parseEther("0.5") })).wait();
  }

  console.log("== deploy the mutual ==");
  const aeds = await new ethers.ContractFactory(art("MockStable").abi, art("MockStable").bytecode, funder).deploy();
  await aeds.waitForDeployment();
  const registry = await new ethers.ContractFactory(art("DamanRegistry").abi, art("DamanRegistry").bytecode, funder).deploy();
  await registry.waitForDeployment();
  const oracle = await new ethers.ContractFactory(art("DamanOracle").abi, art("DamanOracle").bytecode, funder).deploy(3600, 86400);
  await oracle.waitForDeployment();
  const pricing = await new ethers.ContractFactory(art("DamanPricing").abi, art("DamanPricing").bytecode, funder).deploy();
  await pricing.waitForDeployment();
  const treasury = await new ethers.ContractFactory(art("DamanTreasury").abi, art("DamanTreasury").bytecode, funder)
    .deploy(await aeds.getAddress(), 2000);
  await treasury.waitForDeployment();
  const premiums = await new ethers.ContractFactory(art("DamanPremiums").abi, art("DamanPremiums").bytecode, funder)
    .deploy(await aeds.getAddress());
  await premiums.waitForDeployment();
  const policies = await new ethers.ContractFactory(art("DamanPolicies").abi, art("DamanPolicies").bytecode, funder)
    .deploy(await registry.getAddress(), await pricing.getAddress(), await premiums.getAddress(), await treasury.getAddress(), await aeds.getAddress());
  await policies.waitForDeployment();
  const claims = await new ethers.ContractFactory(art("DamanClaims").abi, art("DamanClaims").bytecode, funder)
    .deploy(await registry.getAddress(), await policies.getAddress(), await premiums.getAddress());
  await claims.waitForDeployment();
  const parametric = await new ethers.ContractFactory(art("DamanParametric").abi, art("DamanParametric").bytecode, funder)
    .deploy(await registry.getAddress(), await oracle.getAddress(), await premiums.getAddress(), await treasury.getAddress(), await aeds.getAddress());
  await parametric.waitForDeployment();
  const reinsurance = await new ethers.ContractFactory(art("DamanReinsurance").abi, art("DamanReinsurance").bytecode, funder)
    .deploy(await premiums.getAddress(), await aeds.getAddress());
  await reinsurance.waitForDeployment();
  const surplus = await new ethers.ContractFactory(art("DamanSurplus").abi, art("DamanSurplus").bytecode, funder)
    .deploy(await policies.getAddress(), await premiums.getAddress());
  await surplus.waitForDeployment();
  const governor = await new ethers.ContractFactory(art("DamanGovernor").abi, art("DamanGovernor").bytecode, funder)
    .deploy(await policies.getAddress(), await pricing.getAddress(), await premiums.getAddress(), await claims.getAddress(), await parametric.getAddress(), await reinsurance.getAddress(), await surplus.getAddress(), await treasury.getAddress(), await oracle.getAddress(), await registry.getAddress(), 0);
  await governor.waitForDeployment();

  // wiring
  await (await claims.grantRole(await claims.ADJUSTER_ROLE(), adjuster1.address)).wait();
  await (await claims.grantRole(await claims.ADJUSTER_ROLE(), adjuster2.address)).wait();
  await (await policies.grantRole(await policies.OPERATOR_ROLE(), await claims.getAddress())).wait();
  await (await premiums.grantRole(await premiums.CLAIMS_ROLE(), await claims.getAddress())).wait();
  await (await premiums.grantRole(await premiums.PARAMETRIC_ROLE(), await parametric.getAddress())).wait();
  await (await premiums.grantRole(await premiums.REINSURANCE_ROLE(), await reinsurance.getAddress())).wait();
  await (await premiums.grantRole(await premiums.SURPLUS_ROLE(), await surplus.getAddress())).wait();
  await (await pricing.transferOwnership(await governor.getAddress())).wait();
  const conditionId = await (await oracle.addCondition(ethers.ZeroAddress, 2, 180)).wait().then(() => 0n); // 2 = MeasurementAbove

  async function fund(who, amount, to) {
    await (await aeds.mint(who.address, amount)).wait();
    await (await aeds.connect(who).approve(to, amount)).wait();
  }

  console.log("== seed pools ==");
  await fund(funder, ethers.parseEther("1000000"), await premiums.getAddress());
  await (await premiums.fundPool(1, ethers.parseEther("500000"))).wait();
  await (await premiums.fundPool(2, ethers.parseEther("100000"))).wait(); // FlightDelay pool for parametric
  await fund(funder, ethers.parseEther("100000"), await reinsurance.getAddress());
  await (await reinsurance.fundPool(1, ethers.parseEther("100000"))).wait();
  check("travel pool funded", (await premiums.pool(1)) >= ethers.parseEther("500000"));

  console.log("== policy + claim ==");
  await (await registry.connect(holder).register(1)).wait();
  await fund(holder, ethers.parseEther("100000"), await policies.getAddress());
  await (await policies.connect(holder).buyPolicy(1, 1, ethers.parseEther("10000"), 30n)).wait();
  check("policy active", (await policies.isActivePolicy(0)) === true);
  await (await claims.connect(holder).fileClaim(0, ethers.parseEther("2000"), "lost luggage", ethers.id("ev"))).wait();
  await (await claims.connect(adjuster1).voteClaim(0, true)).wait();
  const before = await aeds.balanceOf(holder.address);
  await (await claims.connect(adjuster2).voteClaim(0, true)).wait();
  check("claim paid 2,000", (await aeds.balanceOf(holder.address)) - before === ethers.parseEther("2000"));

  console.log("== parametric ==");
  await fund(holder, ethers.parseEther("10000"), await parametric.getAddress());
  await (await parametric.connect(holder).buyCover(conditionId, ethers.parseEther("1000"), 7n)).wait();
  await (await oracle.postMeasurement(ethers.toBeHex(conditionId, 32), 240)).wait(); // delay 240 > 180
  await provider.send("evm_increaseTime", [8 * 86400]);
  await provider.send("evm_mine", []);
  await (await funder.sendTransaction({ to: funderAddr, value: 0n })).wait();
  const stored = await oracle.measurements(ethers.ZeroHash);
  const cond = await oracle.conditions(conditionId);
  console.log("  [debug] measurement stored:", stored.toString(), "| cond type:", cond.condType, "| threshold:", cond.threshold, "| active:", cond.active);
  const triggered = await oracle.checkCondition(conditionId);
  console.log("  [debug] condition triggered:", triggered);
  const before2 = await aeds.balanceOf(holder.address);
  await (await parametric.settle(0)).wait();
  console.log("  [debug] delta:", (await aeds.balanceOf(holder.address)) - before2);
  check("parametric paid 1,000", (await aeds.balanceOf(holder.address)) - before2 === ethers.parseEther("1000"));

  console.log("== governance ==");
  await (await governor.connect(funder).recordPremium(holder.address, ethers.parseEther("100"))).wait();
  const calldata = pricing.interface.encodeFunctionData("setBaseRate", [1, 350]);
  await (await governor.connect(funder).propose(await pricing.getAddress(), 0n, calldata, "Raise travel rate to 3.5%")).wait();
  await provider.send("evm_increaseTime", [3 * 86400]);
  await provider.send("evm_mine", []);
  await (await funder.sendTransaction({ to: funderAddr, value: 0n })).wait();
  await (await governor.connect(holder).vote(0, true)).wait();
  await provider.send("evm_increaseTime", [10 * 86400]);
  await provider.send("evm_mine", []);
  await (await funder.sendTransaction({ to: funderAddr, value: 0n })).wait();
  check("proposal succeeded", Number(await governor.state(0)) === 3);
  await (await governor.execute(0)).wait();
  check("travel rate 3.5%", (await pricing.baseRateBps(1)) === 350n);

  console.log("\n" + (failed === 0 ? "SMOKE TEST PASSED" : "SMOKE TEST FAILED") + " — " + passed + " passed, " + failed + " failed");
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
