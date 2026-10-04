/* ============================================================
   Huwiyya dApp — end-to-end smoke test (Node, no npm)
   Deploys the FULL identity stack and walks the credential cycle:
   DID → schema → credential issue → selective disclosure →
   attestation → reputation → gate check → social recovery → governance.

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
  function hashPair(a, b) {
    const x = a < b ? a : b, y = a < b ? b : a;
    return ethers.keccak256(ethers.concat([x, y]));
  }
  global.window = {};
  require(path.join(__dirname, "..", "js", "abi.js"));
  const art = (name) => JSON.parse(fs.readFileSync(path.join(__dirname, "..", "..", "out", name + ".sol", name + ".json"), "utf8"));

  const provider = new ethers.JsonRpcProvider(RPC);
  const funder = new ethers.Wallet(FUNDER_KEY, provider);
  const funderAddr = funder.address;

  const holder = ethers.Wallet.createRandom().connect(provider);
  const guardian1 = ethers.Wallet.createRandom().connect(provider);
  const guardian2 = ethers.Wallet.createRandom().connect(provider);
  for (const w of [holder, guardian1, guardian2]) {
    await (await funder.sendTransaction({ to: w.address, value: ethers.parseEther("0.5") })).wait();
  }

  console.log("== deploy the identity stack ==");
  const fee = await new ethers.ContractFactory(art("MockStable").abi, art("MockStable").bytecode, funder).deploy();
  await fee.waitForDeployment();
  const registry = await new ethers.ContractFactory(art("HuwiyyaRegistry").abi, art("HuwiyyaRegistry").bytecode, funder).deploy();
  await registry.waitForDeployment();
  const schemas = await new ethers.ContractFactory(art("HuwiyyaSchema").abi, art("HuwiyyaSchema").bytecode, funder).deploy();
  await schemas.waitForDeployment();
  const treasury = await new ethers.ContractFactory(art("HuwiyyaTreasury").abi, art("HuwiyyaTreasury").bytecode, funder)
    .deploy(await fee.getAddress(), 2000);
  await treasury.waitForDeployment();
  const credentials = await new ethers.ContractFactory(art("HuwiyyaCredentials").abi, art("HuwiyyaCredentials").bytecode, funder)
    .deploy(await registry.getAddress(), await schemas.getAddress(), await treasury.getAddress(), await fee.getAddress());
  await credentials.waitForDeployment();
  const attestations = await new ethers.ContractFactory(art("HuwiyyaAttestations").abi, art("HuwiyyaAttestations").bytecode, funder)
    .deploy(await registry.getAddress());
  await attestations.waitForDeployment();
  const reputation = await new ethers.ContractFactory(art("HuwiyyaReputation").abi, art("HuwiyyaReputation").bytecode, funder)
    .deploy(await attestations.getAddress());
  await reputation.waitForDeployment();
  const gates = await new ethers.ContractFactory(art("HuwiyyaGates").abi, art("HuwiyyaGates").bytecode, funder)
    .deploy(await registry.getAddress(), await credentials.getAddress(), await reputation.getAddress());
  await gates.waitForDeployment();
  const recovery = await new ethers.ContractFactory(art("HuwiyyaRecovery").abi, art("HuwiyyaRecovery").bytecode, funder)
    .deploy(await registry.getAddress());
  await recovery.waitForDeployment();
  const governor = await new ethers.ContractFactory(art("HuwiyyaGovernor").abi, art("HuwiyyaGovernor").bytecode, funder)
    .deploy(await reputation.getAddress(), await registry.getAddress(), await credentials.getAddress(), await attestations.getAddress(), await gates.getAddress(), await recovery.getAddress(), await treasury.getAddress(), await schemas.getAddress(), 300);
  await governor.waitForDeployment();

  // wiring
  await (await registry.grantRole(await registry.RECOVERY_ROLE(), await recovery.getAddress())).wait();
  await (await credentials.grantRole(await credentials.DEFAULT_ADMIN_ROLE(), await governor.getAddress())).wait();
  await (await attestations.setWeight(funderAddr, 10000)).wait();
  const names = ["name", "dob", "nationality"];
  await (await schemas.publishSchema("IdentityCard", 1, names, [0, 1, 0])).wait();
  await (await fee.mint(funderAddr, ethers.parseEther("100"))).wait();
  await (await fee.approve(await credentials.getAddress(), ethers.parseEther("100"))).wait();

  console.log("== DID + credential ==");
  await (await registry.connect(holder).createDid(ethers.id("doc"))).wait();
  check("DID created", (await registry.isActive(holder.address)) === true);
  const claimName = ethers.keccak256(ethers.toUtf8Bytes("Ali"));
  const claimDob = ethers.keccak256(ethers.toBeHex(1990, 32)); // abi-encoded uint256
  const claimNat = ethers.keccak256(ethers.toUtf8Bytes("UAE"));
  const level1 = hashPair(claimName, claimDob);
  const level1b = hashPair(claimNat, ethers.ZeroHash);
  const root = hashPair(level1, level1b);
  const proof = [claimName, level1b];
  await (await credentials.issue(holder.address, 0n, root, 0n, true)).wait();
  check("credential issued", (await credentials.isValid(0)) === true);
  const stored = await credentials.credentials(0);
  console.log("  [debug] js root :", root);
  console.log("  [debug] on-chain:", stored.claimsRoot);
  console.log("  [debug] claimDob:", claimDob);
  console.log("  [debug] proof0  :", proof[0]);
  console.log("  [debug] proof1  :", proof[1]);

  console.log("== selective disclosure ==");
  const ok = await credentials.connect(holder).present.staticCall(0, funderAddr, 1, claimDob, proof);
  check("dob proved without revealing name/nationality", ok === true);

  console.log("== attestation + gate ==");
  await (await attestations.submit(holder.address, 1, 1000, 0n, ethers.id("kyc"))).wait();
  const score = await reputation.scoreOf(holder.address);
  check("reputation > 0", score > 0n);
  await (await reputation.checkpoint(holder.address)).wait(); // snapshot for voting
  await (await gates.createPolicy([0n], 300n, 1, 1990)).wait();
  check("gate grants access", (await gates.checkAccess(0, holder.address)) === true);

  console.log("== social recovery ==");
  await (await recovery.connect(holder).setGuardians([guardian1.address, guardian2.address])).wait();
  await (await recovery.connect(holder).initiate(funderAddr)).wait();
  await (await recovery.connect(guardian1).approve(0)).wait();
  await provider.send("evm_increaseTime", [2 * 86400]);
  await provider.send("evm_mine", []);
  await (await funder.sendTransaction({ to: funderAddr, value: 0n })).wait();
  await (await recovery.connect(guardian2).approve(0)).wait();
  const did = await registry.dids(holder.address);
  check("key rotated to funder", did.primaryKey === funderAddr);

  console.log("== governance ==");
  const calldata = credentials.interface.encodeFunctionData("setIssuanceFee", [ethers.parseEther("10")]);
  await (await governor.connect(funder).propose(await credentials.getAddress(), 0n, calldata, "Raise issuance fee to 10")).wait();
  await provider.send("evm_increaseTime", [3 * 86400]);
  await provider.send("evm_mine", []);
  await (await funder.sendTransaction({ to: funderAddr, value: 0n })).wait();
  await (await governor.connect(holder).vote(0, true)).wait();
  await provider.send("evm_increaseTime", [10 * 86400]);
  await provider.send("evm_mine", []);
  await (await funder.sendTransaction({ to: funderAddr, value: 0n })).wait();
  check("proposal succeeded", Number(await governor.state(0)) === 3);
  await (await governor.execute(0)).wait();
  check("issuance fee 10", (await credentials.issuanceFee()) === ethers.parseEther("10"));

  console.log("\n" + (failed === 0 ? "SMOKE TEST PASSED" : "SMOKE TEST FAILED") + " — " + passed + " passed, " + failed + " failed");
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
