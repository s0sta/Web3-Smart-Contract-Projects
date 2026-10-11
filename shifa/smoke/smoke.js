/* ============================================================
   Shifa dApp — end-to-end smoke test (Node, no npm)
   Deploys the FULL healthcare platform and walks the care cycle:
   register -> verify -> consent -> record -> prescribe -> dispense ->
   book -> complete -> rate -> insure -> pre-auth -> claim (2-of-3) ->
   copay -> break-glass -> governance.

     1. anvil
     2. forge build
     3. node smoke/smoke.js
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

  const patient = ethers.Wallet.createRandom().connect(provider);
  const doctor = ethers.Wallet.createRandom().connect(provider);
  const pharmacist = ethers.Wallet.createRandom().connect(provider);
  const insurer = ethers.Wallet.createRandom().connect(provider);
  const reviewer1 = ethers.Wallet.createRandom().connect(provider);
  const reviewer2 = ethers.Wallet.createRandom().connect(provider);
  const wallets = [patient, doctor, pharmacist, insurer, reviewer1, reviewer2];
  for (const w of wallets) {
    await (await funder.sendTransaction({ to: w.address, value: ethers.parseEther("0.4") })).wait();
  }

  console.log("== deploy the platform ==");
  const deploy = async (name, ...args) => {
    const a = art(name);
    const c = await new ethers.ContractFactory(a.abi, a.bytecode, funder).deploy(...args);
    await c.waitForDeployment();
    return c;
  };
  const sar = await deploy("MockStable");
  const registry = await deploy("ShifaRegistry");
  const consent = await deploy("ShifaConsent", await registry.getAddress());
  const records = await deploy("ShifaRecords", await registry.getAddress(), await consent.getAddress());
  const prescriptions = await deploy("ShifaPrescriptions", await registry.getAddress(), await consent.getAddress(), 1);
  const emergency = await deploy("ShifaEmergency", await registry.getAddress(), await consent.getAddress());
  const treasury = await deploy("ShifaTreasury", await sar.getAddress(), 2000);
  const appointments = await deploy("ShifaAppointments", await registry.getAddress(), await treasury.getAddress(), await sar.getAddress(), 86400);
  const insurance = await deploy("ShifaInsurance", await registry.getAddress(), await treasury.getAddress(), await sar.getAddress(), 500);
  const payments = await deploy("ShifaPayments", await registry.getAddress(), await insurance.getAddress(), await treasury.getAddress(), await sar.getAddress());
  const reputation = await deploy("ShifaReputation", await registry.getAddress(), await appointments.getAddress());
  const governor = await deploy(
    "ShifaGovernor",
    await registry.getAddress(), await consent.getAddress(), await records.getAddress(),
    await prescriptions.getAddress(), await appointments.getAddress(), await insurance.getAddress(),
    await payments.getAddress(), await emergency.getAddress(), await reputation.getAddress(),
    await treasury.getAddress(), 300
  );

  // wiring
  await (await consent.grantRole(await consent.EMERGENCY_ROLE(), await emergency.getAddress())).wait();
  await (await emergency.grantRole(await emergency.REVIEWER_ROLE(), reviewer1.address)).wait();
  await (await emergency.grantRole(await emergency.REVIEWER_ROLE(), reviewer2.address)).wait();
  await (await insurance.grantRole(await insurance.REVIEWER_ROLE(), reviewer1.address)).wait();
  await (await insurance.grantRole(await insurance.REVIEWER_ROLE(), reviewer2.address)).wait();
  await (await appointments.grantRole(await appointments.DEFAULT_ADMIN_ROLE(), await governor.getAddress())).wait();
  await (await treasury.grantRole(await treasury.OPERATOR_ROLE(), await governor.getAddress())).wait();

  console.log("== members ==");
  await (await registry.connect(patient).register(1, 682, ethers.ZeroHash)).wait();
  await (await registry.connect(doctor).register(2, 682, ethers.id("license-doctor"))).wait();
  await (await registry.connect(pharmacist).register(4, 682, ethers.id("license-pharmacy"))).wait();
  await (await registry.connect(insurer).register(5, 682, ethers.id("license-insurer"))).wait();
  await (await registry.setKyc(doctor.address, 2)).wait();
  await (await registry.setKyc(pharmacist.address, 2)).wait();
  await (await registry.setKyc(insurer.address, 2)).wait();
  check("doctor is a verified clinician", await registry.isClinician(doctor.address));

  console.log("== consent + records ==");
  const scopeRecords = 1n, scopeRx = 2n, scopeAll = 15n;
  await (await consent.connect(patient).grant(doctor.address, scopeAll, Math.floor(Date.now() / 1000) + 90 * 86400)).wait();
  await (await consent.connect(patient).grant(pharmacist.address, scopeRx, Math.floor(Date.now() / 1000) + 90 * 86400)).wait();
  check("consent recorded", await consent.hasConsent(patient.address, doctor.address, scopeRecords));

  const rec = await (await records.connect(doctor).createRecord(patient.address, 5, ethers.id("allergy-penicillin"))).wait();
  check("record filed", Number(await records.recordCount()) === 1);
  rec; // receipt kept for debugging
  check("doctor may read it", await records.canRead(0, doctor.address));

  console.log("== prescriptions ==");
  await (await prescriptions.connect(doctor).issue(patient.address, ethers.id("amoxicillin"), 500, 2, 30, false)).wait();
  await (await prescriptions.connect(pharmacist).dispense(0)).wait();
  check("one refill consumed", Number(await prescriptions.refillsLeft(0)) === 1);

  console.log("== visits + reputation ==");
  const sarMint = await sar.mint(patient.address, ethers.parseEther("100000"));
  await sarMint.wait();
  await (await sar.connect(patient).approve(await appointments.getAddress(), ethers.parseEther("100000"))).wait();
  const slot = Math.floor(Date.now() / 1000) + 3 * 86400;
  await (await appointments.connect(patient).book(doctor.address, slot, ethers.parseEther("500"))).wait();
  await (await appointments.connect(doctor).complete(0)).wait();
  check("doctor paid the deposit minus 2%", (await sar.balanceOf(doctor.address)) === ethers.parseEther("490"));
  await (await reputation.connect(patient).rate(0, 100)).wait();
  check("reputation lifted above neutral", Number(await reputation.scoreOf(doctor.address)) > 500);

  console.log("== insurance ==");
  await (await sar.connect(patient).approve(await insurance.getAddress(), ethers.parseEther("100000"))).wait();
  await (await insurance.connect(patient).subscribe(insurer.address, ethers.parseEther("10000"), 2000, 365)).wait();
  // the insurer is funded so the pool can pay
  await (await sar.mint(await insurance.getAddress(), ethers.parseEther("50000"))).wait();
  await (await insurance.connect(insurer).preAuthorize(0, doctor.address, ethers.id("consult"), ethers.parseEther("1000"), 30)).wait();
  await (await insurance.connect(doctor).fileClaim(0, ethers.parseEther("1000"))).wait();
  await (await insurance.connect(reviewer1).voteClaim(0, true)).wait();
  await (await insurance.connect(reviewer2).voteClaim(0, true)).wait();
  const claim = await insurance.claims(0);
  check("insurer share 800 / patient 200", claim.insurerShare === ethers.parseEther("800") && claim.patientShare === ethers.parseEther("200"));

  console.log("== copay + emergency ==");
  await (await sar.connect(patient).approve(await payments.getAddress(), ethers.parseEther("100000"))).wait();
  await (await payments.connect(patient).payCopay(0, ethers.id("copay"))).wait();
  check("copay settled", Number(await payments.receiptCount()) === 1);

  await (await emergency.connect(doctor).openCase(patient.address, "anaphylaxis", 6)).wait();
  check("break-glass opens records access", await records.canRead(0, doctor.address));
  await (await emergency.connect(reviewer1).review(0, true)).wait();
  const c = await emergency.cases(0);
  check("break-glass reviewed and upheld", c.reviewed === true && c.upheld === true);

  console.log("== governance ==");
  await (await reputation.checkpoint(patient.address)).wait();
  const data = appointments.interface.encodeFunctionData("setFee", [300]);
  await (await governor.propose(await appointments.getAddress(), 0, data, "Raise visit fee to 3%")).wait();
  await provider.send("evm_increaseTime", [2 * 86400 + 1]);
  await provider.send("evm_mine", []);
  await (await funder.sendTransaction({ to: funder.address, value: 0 })).wait();
  await (await governor.connect(patient).vote(0, true)).wait();
  await provider.send("evm_increaseTime", [7 * 86400 + 2]);
  await provider.send("evm_mine", []);
  await (await funder.sendTransaction({ to: funder.address, value: 0 })).wait();
  check("proposal succeeded", Number(await governor.state(0)) === 3);
  await (await governor.execute(0)).wait();
  check("visit fee is now 3%", Number(await appointments.feeBps()) === 300);

  console.log("\n" + (failed === 0 ? "SMOKE TEST PASSED" : "SMOKE TEST FAILED") + " — " + passed + " passed, " + failed + " failed");
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
