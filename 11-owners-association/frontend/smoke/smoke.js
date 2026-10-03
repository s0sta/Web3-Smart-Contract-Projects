/* ============================================================
   JOP Owners Association dApp — end-to-end smoke test (Node, no npm)
   Deploys its OWN association with short periods (60s review /
   120s voting / 60s timelock) and walks the full lifecycle.
   Time jumps are anchored by real transactions (anvil).

     1. anvil                        (terminal 1)
     2. forge build                  (artifacts needed)
     3. GOVERNOR=0x… node smoke/smoke.js   (any governor works for the reads)
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
  const ABI_G = window.JOP_GOVERNOR_ABI;
  const ABI_R = window.JOP_REGISTRY_ABI;
  const ABI_T = window.JOP_TREASURY_ABI;
  const ABI_S = window.JOP_STABLE_ABI;

  const provider = new ethers.JsonRpcProvider(RPC);
  const funder = new ethers.NonceManager(new ethers.Wallet(FUNDER_KEY, provider));
  const funderAddr = new ethers.Wallet(FUNDER_KEY).address;
  const ifaceG = new ethers.Interface(ABI_G);

  // fresh participants per run
  const ownerA = ethers.Wallet.createRandom().connect(provider); // 2 units (180 sqm)
  const ownerB = ethers.Wallet.createRandom().connect(provider); // board member (160 sqm)
  const ownerC = ethers.Wallet.createRandom().connect(provider); // compliance (60 sqm)
  for (const w of [ownerA, ownerB, ownerC]) {
    await (await funder.sendTransaction({ to: w.address, value: ethers.parseEther("0.5") })).wait();
  }

  console.log("== deploy association (60s/120s/60s) ==");
  const art = (name) => JSON.parse(fs.readFileSync(path.join(__dirname, "..", "..", "out", name + ".sol", name + ".json"), "utf8"));
  const stable = await new ethers.ContractFactory(art("MockStable").abi, art("MockStable").bytecode, funder).deploy();
  await stable.waitForDeployment();
  const registry = await new ethers.ContractFactory(art("JOPUnitRegistry").abi, art("JOPUnitRegistry").bytecode, funder)
    .deploy(await stable.getAddress(), funderAddr);
  await registry.waitForDeployment();
  const treasury = await new ethers.ContractFactory(art("TreasuryVault").abi, art("TreasuryVault").bytecode, funder)
    .deploy(await stable.getAddress(), funderAddr);
  await treasury.waitForDeployment();

  const board = [ownerB.address];
  const governor = await new ethers.ContractFactory(art("OwnersAssociationGovernor").abi, art("OwnersAssociationGovernor").bytecode, funder)
    .deploy(await registry.getAddress(), await treasury.getAddress(), ownerC.address, funderAddr, board, 60, 120, 60);
  await governor.waitForDeployment();
  const GOV = await governor.getAddress();

  await (await registry.setTreasury(await treasury.getAddress())).wait();
  // units: A=120+60, B=160, C=60
  await (await registry.addUnit(120, ownerA.address)).wait();
  await (await registry.addUnit(60, ownerA.address)).wait();
  await (await registry.addUnit(160, ownerB.address)).wait();
  await (await registry.addUnit(60, ownerC.address)).wait();
  await (await registry.setAnnualChargePerSqm(ethers.parseEther("60"))).wait();
  await (await registry.setAuthority(GOV)).wait();
  await (await treasury.setAuthority(GOV)).wait();
  await (await governor.grantRole(await governor.DEFAULT_ADMIN_ROLE(), GOV)).wait();
  await (await governor.renounceRole(await governor.DEFAULT_ADMIN_ROLE())).wait();

  console.log("== reads ==");
  check("total area 400", (await registry.totalAreaSqm()) === 400n);
  check("board seated", (await governor.boardSeats(0)).toLowerCase() === ownerB.address.toLowerCase());
  check("compliance role", (await governor.hasRole(await governor.COMPLIANCE_ROLE(), ownerC.address)) === true);
  check("admin self-governed", (await governor.hasRole(await governor.DEFAULT_ADMIN_ROLE(), GOV)) === true);

  console.log("== propose (ownerA, 180 sqm ≥ 50) ==");
  const calldata = new ethers.Interface(ABI_T).encodeFunctionData("setReserveBps", [700]);
  const rc = await (await governor.connect(ownerA).propose(3, [await treasury.getAddress()], [0n], [calldata], "Set reserve to 7%")).wait();
  const created = rc.logs.map((l) => { try { return ifaceG.parseLog(l); } catch { return null; } }).find((l) => l && l.name === "ProposalCreated");
  check("ProposalCreated", !!created);
  const pid = Number(created.args.proposalId);
  check("state Review", Number(await governor.state(pid)) === 0);

  console.log("== fast-track (board) ==");
  await (await governor.connect(ownerB).fastTrack(pid)).wait();
  check("state Active", Number(await governor.state(pid)) === 1);

  console.log("== votes (A for 180, B against 160) ==");
  await (await governor.connect(ownerA).vote(pid, true)).wait();
  await (await governor.connect(ownerB).vote(pid, false)).wait();
  const p1 = await governor.proposals(pid);
  check("for = 180", p1.forVotes === 180n);
  check("against = 160", p1.againstVotes === 160n);

  console.log("== voting ends → succeeded (quorum 30% of 400 = 120 ✓) ==");
  await provider.send("evm_increaseTime", [180]);
  await provider.send("evm_mine", []);
  await (await funder.sendTransaction({ to: funderAddr, value: 0n })).wait(); // anchor
  check("state Succeeded", Number(await governor.state(pid)) === 3);

  console.log("== execute → reserve set to 7% ==");
  await (await governor.connect(ownerC).execute(pid)).wait();
  check("state Executed", Number(await governor.state(pid)) === 4);
  check("reserve 7%", (await treasury.reserveBps()) === 700n);

  console.log("== veto flow ==");
  const rc2 = await (await governor.connect(ownerA).propose(0, [await treasury.getAddress()], [0n], [calldata], "Veto me")).wait();
  const created2 = rc2.logs.map((l) => { try { return ifaceG.parseLog(l); } catch { return null; } }).find((l) => l && l.name === "ProposalCreated");
  const pid2 = Number(created2.args.proposalId);
  await (await governor.connect(ownerC).veto(pid2, "regulatory objection")).wait();
  check("state Vetoed", Number(await governor.state(pid2)) === 7);

  console.log("== delegation ==");
  const chainNow = Number((await provider.getBlock('latest')).timestamp);
  await (await governor.connect(ownerB).delegate(ownerA.address, BigInt(chainNow + 3600))).wait();
  check("delegatee set", (await governor.delegatee(ownerB.address)).toLowerCase() === ownerA.address.toLowerCase());
  check("A power 340", (await governor.votingPower(ownerA.address)) === 340n);
  await (await governor.connect(ownerB).revokeDelegation()).wait();
  check("A power back to 180", (await governor.votingPower(ownerA.address)) === 180n);

  console.log("== service charges ==");
  await (await funder.sendTransaction({ to: funderAddr, value: 0n })).wait();
  await provider.send("evm_increaseTime", [365 * 86400]);
  await provider.send("evm_mine", []);
  await (await funder.sendTransaction({ to: funderAddr, value: 0n })).wait();
  await (await registry.accrue(0)).wait();
  const u0 = await registry.units(0);
  check("unit 0 accrued debt > 0", u0.chargeDebt > 0n, u0.chargeDebt.toString());
  // pay in small rounds: each pay accrues first, so a few rounds clear the debt exactly
  const registryAddr = await registry.getAddress();
  for (let round = 0; round < 3; round++) {
    const debt = (await registry.units(0)).chargeDebt;
    if (debt === 0n) break;
    const allowance = await stable.allowance(ownerA.address, registryAddr);
    if (allowance < debt) {
      await (await stable.mint(ownerA.address, debt)).wait();
      await (await stable.connect(ownerA).approve(registryAddr, debt)).wait();
    }
    await (await registry.connect(ownerA).payServiceCharge(0, debt)).wait();
  }
  check("debt cleared (converged to <0.01)", (await registry.units(0)).chargeDebt < ethers.parseEther("0.01"));
  check("treasury received charges", (await stable.balanceOf(await treasury.getAddress())) >= u0.chargeDebt);

  console.log("== errors ==");
  try {
    await governor.connect(ownerC).vote(pid2, true);
    check("vetoed vote reverts", false, "should have reverted");
  } catch { check("vetoed vote reverts", true); }

  console.log("\n" + (failed === 0 ? "SMOKE TEST PASSED" : "SMOKE TEST FAILED") + " — " + passed + " passed, " + failed + " failed");
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
