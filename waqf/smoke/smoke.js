/* ============================================================
   Waqf Endowment dApp — end-to-end smoke test (Node, no npm)
   Deploys its OWN waqf and walks the full lifecycle:
   endow → income → distribute → beneficiary changes → proposal
   (confirm ×2, vote, timelock, execute) → freeze.

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
  const ABI_V = window.WAQF_VAULT_ABI;
  const ABI_R = window.WAQF_REGISTRY_ABI;
  const ABI_G = window.WAQF_GOVERNOR_ABI;
  const ABI_S = window.WAQF_STABLE_ABI;

  const provider = new ethers.JsonRpcProvider(RPC);
  const funder = new ethers.Wallet(FUNDER_KEY, provider);
  const funderAddr = funder.address;

  const donor = ethers.Wallet.createRandom().connect(provider);
  const nazirA = ethers.Wallet.createRandom().connect(provider);
  const nazirB = ethers.Wallet.createRandom().connect(provider);
  const beneficiary = ethers.Wallet.createRandom().connect(provider);
  for (const w of [donor, nazirA, nazirB, beneficiary]) {
    await (await funder.sendTransaction({ to: w.address, value: ethers.parseEther("0.5") })).wait();
  }

  console.log("== deploy waqf ==");
  const art = (name) => JSON.parse(fs.readFileSync(path.join(__dirname, "..", "..", "out", name + ".sol", name + ".json"), "utf8"));
  const stable = await new ethers.ContractFactory(art("MockStable").abi, art("MockStable").bytecode, funder).deploy();
  await stable.waitForDeployment();
  const vault = await new ethers.ContractFactory(art("WaqfVault").abi, art("WaqfVault").bytecode, funder)
    .deploy(await stable.getAddress());
  await vault.waitForDeployment();
  const registry = await new ethers.ContractFactory(art("BeneficiaryRegistry").abi, art("BeneficiaryRegistry").bytecode, funder).deploy();
  await registry.waitForDeployment();
  const governor = await new ethers.ContractFactory(art("WaqfGovernor").abi, art("WaqfGovernor").bytecode, funder)
    .deploy(await vault.getAddress(), await registry.getAddress(), [funderAddr, nazirA.address, nazirB.address], ethers.parseEther("1000"), 1000, 120);
  await governor.waitForDeployment();
  const GOV = await governor.getAddress();

  await (await vault.grantRole(await vault.NAZIR_ROLE(), nazirA.address)).wait();
  await (await vault.grantRole(await vault.NAZIR_ROLE(), nazirB.address)).wait();
  await (await vault.grantRole(await vault.DEFAULT_ADMIN_ROLE(), GOV)).wait();
  await (await vault.grantRole(await vault.NAZIR_ROLE(), GOV)).wait();
  await (await registry.setGovernor(GOV)).wait();
  await (await registry.grantRole(await registry.DEFAULT_ADMIN_ROLE(), GOV)).wait();
  await (await registry.addBeneficiary(funderAddr, 6000)).wait();
  await (await registry.addBeneficiary(beneficiary.address, 4000)).wait();

  console.log("== endowment ==");
  await (await stable.mint(donor.address, ethers.parseEther("50000"))).wait();
  await (await stable.connect(donor).approve(await vault.getAddress(), ethers.parseEther("10000"))).wait();
  await (await vault.connect(donor).endow(ethers.parseEther("10000"))).wait();
  check("corpus 10,000", (await vault.totalCorpus()) === ethers.parseEther("10000"));
  check("donor tracked", (await vault.contributions(donor.address)) === ethers.parseEther("10000"));

  console.log("== income & distribution ==");
  await (await stable.mint(funderAddr, ethers.parseEther("1000"))).wait();
  await (await stable.approve(await vault.getAddress(), ethers.parseEther("1000"))).wait();
  await (await vault.recordIncome(ethers.parseEther("1000"))).wait();
  const targets = await registry.distributionTargets();
  const accounts = Array.from(targets[0]);
  const weights = Array.from(targets[1]);
  await (await vault.distribute(accounts, weights)).wait();
  check("60/40 split", (await stable.balanceOf(beneficiary.address)) === ethers.parseEther("400"));
  check("corpus untouched", (await stable.balanceOf(await vault.getAddress())) === ethers.parseEther("10000"));

  console.log("== governance lifecycle (120s timelock) ==");
  const calldata = registry.interface.encodeFunctionData("setBeneficiaryWeight", [1, 3000]);
  const rc = await (await governor.connect(donor).propose(0, [await registry.getAddress()], [0n], [calldata], "Rebalance the education share to 30%")).wait();
  const ifaceG = new ethers.Interface(ABI_G);
  const created = rc.logs.map((l) => { try { return ifaceG.parseLog(l); } catch { return null; } }).find((l) => l && l.name === "ProposalCreated");
  const pid = Number(created.args.proposalId);
  check("state Confirmation", Number(await governor.state(pid)) === 0);

  await (await governor.connect(nazirA).confirm(pid)).wait();
  await (await governor.connect(nazirB).confirm(pid)).wait();
  await provider.send("evm_increaseTime", [3 * 86400]);
  await provider.send("evm_mine", []);
  await (await funder.sendTransaction({ to: funderAddr, value: 0n })).wait();
  check("state Voting", Number(await governor.state(pid)) === 1);

  await (await governor.connect(donor).vote(pid, true)).wait();
  await provider.send("evm_increaseTime", [7 * 86400 + 180]);
  await provider.send("evm_mine", []);
  await (await funder.sendTransaction({ to: funderAddr, value: 0n })).wait();
  check("state Succeeded", Number(await governor.state(pid)) === 3);

  await (await governor.execute(pid)).wait();
  check("executed", Number(await governor.state(pid)) === 4);
  const b1 = await registry.beneficiaries(1);
  check("weight rebalanced to 30%", b1.weightBps === 3000n);

  console.log("== freeze ==");
  await (await vault.setFrozen(true)).wait();
  try {
    await (await vault.distribute(targets[0], targets[1])).wait();
    check("frozen blocks distribution", false, "should have reverted");
  } catch { check("frozen blocks distribution", true); }
  check("corpus still intact", (await vault.totalCorpus()) === ethers.parseEther("10000"));

  console.log("\n" + (failed === 0 ? "SMOKE TEST PASSED" : "SMOKE TEST FAILED") + " — " + passed + " passed, " + failed + " failed");
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
