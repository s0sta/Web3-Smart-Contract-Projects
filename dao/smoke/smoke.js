/* ============================================================
   Senate DAO dApp — end-to-end smoke test (Node, no npm)
   Verifies the EXACT bundles the site uses (ethers v6 UMD + the
   shipped js/abi.js). Deploys its OWN governor with a 90-second
   voting period, so the full lifecycle is deterministic and the
   test is fully re-runnable.

     1. anvil                        (terminal 1)
     2. forge build                  (so out/ artifacts exist here)
     3. GOVERNOR=0x… node smoke/smoke.js   (any governor works for the reads section)
   ============================================================ */

const fs = require("fs");
const os = require("os");
const path = require("path");

const ETHER_VERSION = "6.13.4";
const ETHER_CDN = `https://cdn.jsdelivr.net/npm/ethers@${ETHER_VERSION}/dist/ethers.umd.min.js`;

const RPC = process.env.RPC || "http://127.0.0.1:8545";
const GOVERNOR = process.env.GOVERNOR;
const FUNDER_KEY = process.env.FUNDER_KEY || "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"; // anvil #0

async function loadEthers() {
  const tmp = path.join(os.tmpdir(), `ethers-${ETHER_VERSION}.umd.min.js`);
  if (!fs.existsSync(tmp)) {
    console.log("Downloading ethers UMD (same bundle the site loads)…");
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
  const ABI_G = window.GOVERNOR_ABI;
  const ABI_T = window.GOV_TOKEN_ABI;

  const provider = new ethers.JsonRpcProvider(RPC);
  const funder = new ethers.Wallet(FUNDER_KEY, provider);
  const ifaceG = new ethers.Interface(ABI_G);

  // fresh voters per run
  const v1 = ethers.Wallet.createRandom().connect(provider);
  const v2 = ethers.Wallet.createRandom().connect(provider);
  const v3 = ethers.Wallet.createRandom().connect(provider);
  for (const w of [v1, v2, v3]) {
    await (await funder.sendTransaction({ to: w.address, value: ethers.parseEther("0.2") })).wait();
  }

  console.log("== deploy own governor (90s voting, 10k threshold, 4% quorum) ==");
  const govArtifact = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "..", "out", "Governor.sol", "Governor.json"), "utf8"));
  const tokArtifact = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "..", "out", "GovToken.sol", "GovToken.json"), "utf8"));
  const token = await new ethers.ContractFactory(tokArtifact.abi, tokArtifact.bytecode, funder)
    .deploy("Governance", "GOV", ethers.parseEther("1000000"), funder.address);
  await token.waitForDeployment();
  const governor = await new ethers.ContractFactory(govArtifact.abi, govArtifact.bytecode, funder)
    .deploy(await token.getAddress(), 90, ethers.parseEther("10000"), 400);
  await governor.waitForDeployment();
  const GOV = await governor.getAddress();

  // distribute voting power
  await (await token.transfer(v1.address, ethers.parseEther("60000"))).wait();
  await (await token.transfer(v2.address, ethers.parseEther("30000"))).wait();
  // v3 stays BELOW the 10,000 threshold on purpose (for the error test)
  await (await token.transfer(v3.address, ethers.parseEther("5000"))).wait();

  console.log("== propose ==");
  const tx = await governor.connect(v1).propose(
    [await token.getAddress()],
    [0n],
    [new ethers.Interface(ABI_T).encodeFunctionData("transfer", [v1.address, 0n])],
    "Pay the contributor 1,000 GOV"
  );
  const rc = await tx.wait();
  const created = rc.logs.map((l) => { try { return ifaceG.parseLog(l); } catch { return null; } }).find((l) => l && l.name === "ProposalCreated");
  check("ProposalCreated event", !!created);
  const pid = Number(created.args.proposalId);
  const p0 = await governor.proposals(pid);
  check("snapshot recorded", Number(p0.snapshotBlock) > 0);
  check("state Active", Number(await governor.state(pid)) === 0);

  console.log("== votes ==");
  await (await governor.connect(v1).vote(pid, true)).wait();
  await (await governor.connect(v2).vote(pid, false)).wait();
  const p1 = await governor.proposals(pid);
  check("for = 60,000", p1.forVotes === ethers.parseEther("60000"));
  check("against = 30,000", p1.againstVotes === ethers.parseEther("30000"));

  try {
    await governor.connect(v1).vote(pid, true);
    check("double vote reverts", false, "should have reverted");
  } catch (err) {
    const e = ifaceG.parseError(err.data);
    check("AlreadyVoted decoded", e && e.name === "AlreadyVoted", e && e.name);
  }

  console.log("== deadline passes → succeeded → execute ==");
  await provider.send("evm_increaseTime", [600]);
  await provider.send("evm_mine", []);
  // anchor on a committed tx so reads and the execute call see the advanced time
  await (await funder.sendTransaction({ to: funder.address, value: 0n })).wait();
  check("state Succeeded", Number(await governor.state(pid)) === 1);
  const exec = await (await governor.connect(v3).execute(pid)).wait();
  const execEv = exec.logs.map((l) => { try { return ifaceG.parseLog(l); } catch { return null; } }).find((l) => l && l.name === "ProposalExecuted");
  check("ProposalExecuted event", !!execEv);
  check("state Executed", Number(await governor.state(pid)) === 3);

  console.log("== cancel flow ==");
  const tx2 = await governor.connect(v1).propose(
    [await token.getAddress()],
    [0n],
    ["0x"],
    "Cancel me"
  );
  const rc2 = await tx2.wait();
  const created2 = rc2.logs.map((l) => { try { return ifaceG.parseLog(l); } catch { return null; } }).find((l) => l && l.name === "ProposalCreated");
  const pid2 = Number(created2.args.proposalId);
  await (await governor.connect(v1).cancel(pid2)).wait();
  check("state Canceled", Number(await governor.state(pid2)) === 4);
  try {
    await governor.connect(v2).cancel(pid2);
    check("non-proposer cancel reverts", false, "should have reverted");
  } catch (err) {
    const e = ifaceG.parseError(err.data);
    check("NotProposer decoded", e && e.name === "NotProposer", e && e.name);
  }

  console.log("== errors ==");
  try {
    await governor.connect(v3).propose([await token.getAddress()], [0n], ["0x"], "Too few votes");
    check("below threshold reverts", false, "should have reverted");
  } catch (err) {
    const e = ifaceG.parseError(err.data);
    check("BelowProposalThreshold decoded", e && e.name === "BelowProposalThreshold", e && e.name);
  }
  try {
    await governor.connect(v1).execute(pid2);
    check("execute canceled reverts", false, "should have reverted");
  } catch (err) {
    const e = ifaceG.parseError(err.data);
    check("ProposalNotSucceeded decoded", e && e.name === "ProposalNotSucceeded", e && e.name);
  }

  console.log("== event feed (the dApp's getLogs flow) ==");
  const latest = await provider.getBlockNumber();
  const logs = await provider.getLogs({ address: GOV, fromBlock: 0, toBlock: latest });
  const decoded = logs.map((l) => { try { return ifaceG.parseLog(l); } catch { return null; } }).filter(Boolean);
  const names = decoded.map((d) => d.name);
  for (const n of ["ProposalCreated", "VoteCast", "ProposalExecuted", "ProposalCanceled"]) {
    check(n + " present", names.includes(n));
  }

  console.log("\n" + (failed === 0 ? "SMOKE TEST PASSED" : "SMOKE TEST FAILED") + " — " + passed + " passed, " + failed + " failed");
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
