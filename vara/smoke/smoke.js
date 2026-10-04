/* ============================================================
   VARA Treasury dApp — end-to-end smoke test (Node, no npm)
   Deploys its OWN treasury and walks the regulatory lifecycle:
   KYC → deposit → limit window → reserve breach → counterparty →
   freeze + forced transfer → pause → emergency drain.

     1. anvil
     2. forge build
     3. TREASURY=0x… node smoke/smoke.js
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
  const ABI_T = window.VARA_TREASURY_ABI;
  const ABI_C = window.VARA_COMPLIANCE_ABI;
  const ABI_S = window.VARA_STABLE_ABI;

  const provider = new ethers.JsonRpcProvider(RPC);
  const funder = new ethers.Wallet(FUNDER_KEY, provider);
  const funderAddr = funder.address;

  const officer = ethers.Wallet.createRandom().connect(provider);
  const guardian = ethers.Wallet.createRandom().connect(provider);
  const client = ethers.Wallet.createRandom().connect(provider);
  const bank = ethers.Wallet.createRandom().connect(provider);
  for (const w of [officer, guardian, client, bank]) {
    await (await funder.sendTransaction({ to: w.address, value: ethers.parseEther("0.5") })).wait();
  }

  console.log("== deploy treasury ==");
  const art = (name) => JSON.parse(fs.readFileSync(path.join(__dirname, "..", "..", "out", name + ".sol", name + ".json"), "utf8"));
  const stable = await new ethers.ContractFactory(art("MockStable").abi, art("MockStable").bytecode, funder).deploy();
  await stable.waitForDeployment();
  const compliance = await new ethers.ContractFactory(art("ComplianceModule").abi, art("ComplianceModule").bytecode, funder)
    .deploy([officer.address]);
  await compliance.waitForDeployment();
  const treasury = await new ethers.ContractFactory(art("VASPTreasury").abi, art("VASPTreasury").bytecode, funder)
    .deploy(await compliance.getAddress(), 2000, guardian.address);
  await treasury.waitForDeployment();
  const TRS = await treasury.getAddress();

  await (await compliance.grantRole(await compliance.COMPLIANCE_ROLE(), TRS)).wait();
  await (await treasury.grantRole(await treasury.GUARDIAN_ROLE(), guardian.address)).wait();
  await (await treasury.grantRole(await treasury.COMPLIANCE_ROLE(), officer.address)).wait();
  await (await treasury.listAsset(await stable.getAddress())).wait();
  // house equity: 30k at 20% reserve covers up to 150k of liabilities
  await (await stable.mint(funderAddr, ethers.parseEther("30000"))).wait();
  await (await stable.approve(TRS, ethers.parseEther("30000"))).wait();
  await (await treasury.operatorDeposit(await stable.getAddress(), ethers.parseEther("30000"))).wait();

  console.log("== KYC + deposits ==");
  await (await compliance.connect(officer).setKyc(client.address, 2)).wait(); // Enhanced
  await (await stable.mint(client.address, ethers.parseEther("100000"))).wait();
  await (await stable.connect(client).approve(TRS, ethers.parseEther("100000"))).wait();
  await (await treasury.connect(client).deposit(await stable.getAddress(), ethers.parseEther("100000"))).wait();
  check("client ledger 100k", (await treasury.clientBalances(await stable.getAddress(), client.address)) === ethers.parseEther("100000"));
  check("house untouched", (await treasury.houseBalances(await stable.getAddress())) === ethers.parseEther("30000"));

  console.log("== withdrawal limits (Enhanced: 100k/tx, 500k/day) ==");
  await (await treasury.connect(client).withdraw(await stable.getAddress(), client.address, ethers.parseEther("10000"))).wait();
  check("withdraw ok", (await treasury.clientBalances(await stable.getAddress(), client.address)) === ethers.parseEther("90000"));

  console.log("== counterparty rule ==");
  try {
    await treasury.connect(client).withdraw(await stable.getAddress(), bank.address, ethers.parseEther("1"));
    check("non-approved counterparty blocked", false, "should have reverted");
  } catch { check("non-approved counterparty blocked", true); }
  await (await compliance.connect(officer).setCounterparty(bank.address, true)).wait();
  await (await treasury.connect(client).withdraw(await stable.getAddress(), bank.address, ethers.parseEther("5000"))).wait();
  check("approved counterparty ok", (await stable.balanceOf(bank.address)) === ethers.parseEther("5000"));

  console.log("== reserve enforcement ==");
  // liabilities 85k → house needed 17k ≤ 30k ✓; push liabilities over capacity
  await (await stable.mint(client.address, ethers.parseEther("80000"))).wait();
  await (await stable.connect(client).approve(TRS, ethers.parseEther("80000"))).wait();
  await (await treasury.connect(client).deposit(await stable.getAddress(), ethers.parseEther("80000"))).wait(); // 165k total
  try {
    await treasury.connect(client).withdraw(await stable.getAddress(), client.address, ethers.parseEther("1"));
    check("reserve breach blocked", false, "should have reverted");
  } catch { check("reserve breach blocked", true); }

  console.log("== compliance freeze + forced transfer ==");
  await (await treasury.connect(officer).freezeAccount(client.address)).wait();
  try {
    await treasury.connect(client).withdraw(await stable.getAddress(), client.address, ethers.parseEther("1"));
    check("frozen client blocked", false, "should have reverted");
  } catch { check("frozen client blocked", true); }
  await (await treasury.connect(officer).forcedTransfer(client.address, await stable.getAddress(), ethers.parseEther("1000"))).wait();
  check("forced transfer to recovery", (await treasury.clientBalances(await stable.getAddress(), guardian.address)) === ethers.parseEther("1000"));

  console.log("== guardian pause + emergency drain ==");
  await (await treasury.connect(guardian).pause()).wait();
  const tokens = [await stable.getAddress()];
  await (await treasury.connect(guardian).emergencyDrainAssets(tokens)).wait();
  check("drain moves everything", (await treasury.clientTotals(await stable.getAddress())) === 0n);
  check("recovery holds funds", (await stable.balanceOf(guardian.address)) > ethers.parseEther("30000"));

  console.log("\n" + (failed === 0 ? "SMOKE TEST PASSED" : "SMOKE TEST FAILED") + " — " + passed + " passed, " + failed + " failed");
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
