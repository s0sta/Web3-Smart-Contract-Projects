/* ============================================================
   Taqa dApp — end-to-end smoke test (Node, no npm)
   Deploys the FULL energy market and walks the sustainability cycle:
   register → meter → attest → mint RECs → market order → fill →
   retire → P2P energy → governance.

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

  const producer = ethers.Wallet.createRandom().connect(provider);
  const consumer = ethers.Wallet.createRandom().connect(provider);
  const auditor = ethers.Wallet.createRandom().connect(provider);
  for (const w of [producer, consumer, auditor]) {
    await (await funder.sendTransaction({ to: w.address, value: ethers.parseEther("0.5") })).wait();
  }

  console.log("== deploy the market ==");
  const aeds = await new ethers.ContractFactory(art("MockStable").abi, art("MockStable").bytecode, funder).deploy();
  await aeds.waitForDeployment();
  const registry = await new ethers.ContractFactory(art("TaqaRegistry").abi, art("TaqaRegistry").bytecode, funder).deploy();
  await registry.waitForDeployment();
  const oracle = await new ethers.ContractFactory(art("TaqaOracle").abi, art("TaqaOracle").bytecode, funder).deploy(3600, 86400);
  await oracle.waitForDeployment();
  const meters = await new ethers.ContractFactory(art("TaqaMeters").abi, art("TaqaMeters").bytecode, funder)
    .deploy(await registry.getAddress(), await oracle.getAddress());
  await meters.waitForDeployment();
  const certificates = await new ethers.ContractFactory(art("TaqaCertificates").abi, art("TaqaCertificates").bytecode, funder)
    .deploy(await registry.getAddress(), await meters.getAddress());
  await certificates.waitForDeployment();
  const carbon = await new ethers.ContractFactory(art("TaqaCarbon").abi, art("TaqaCarbon").bytecode, funder)
    .deploy(await registry.getAddress());
  await carbon.waitForDeployment();
  const treasury = await new ethers.ContractFactory(art("TaqaTreasury").abi, art("TaqaTreasury").bytecode, funder)
    .deploy(await aeds.getAddress(), 2000);
  await treasury.waitForDeployment();
  const market = await new ethers.ContractFactory(art("TaqaMarket").abi, art("TaqaMarket").bytecode, funder)
    .deploy(await registry.getAddress(), await certificates.getAddress(), await carbon.getAddress(), await treasury.getAddress(), await aeds.getAddress());
  await market.waitForDeployment();
  const p2p = await new ethers.ContractFactory(art("TaqaP2P").abi, art("TaqaP2P").bytecode, funder)
    .deploy(await registry.getAddress(), await oracle.getAddress(), await treasury.getAddress(), await aeds.getAddress());
  await p2p.waitForDeployment();
  const retirement = await new ethers.ContractFactory(art("TaqaRetirement").abi, art("TaqaRetirement").bytecode, funder)
    .deploy(await registry.getAddress(), await certificates.getAddress(), await carbon.getAddress());
  await retirement.waitForDeployment();
  const compliance = await new ethers.ContractFactory(art("TaqaCompliance").abi, art("TaqaCompliance").bytecode, funder)
    .deploy(await registry.getAddress());
  await compliance.waitForDeployment();
  const governor = await new ethers.ContractFactory(art("TaqaGovernor").abi, art("TaqaGovernor").bytecode, funder)
    .deploy(await registry.getAddress(), await compliance.getAddress(), await meters.getAddress(), await certificates.getAddress(), await carbon.getAddress(), await market.getAddress(), await p2p.getAddress(), await retirement.getAddress(), await treasury.getAddress(), await oracle.getAddress(), 0);
  await governor.waitForDeployment();

  // wiring
  await (await compliance.setZoneAllowed(784, true)).wait();
  await (await certificates.grantRole(await certificates.AUDITOR_ROLE(), auditor.address)).wait();
  await (await certificates.grantRole(await certificates.MARKET_ROLE(), await market.getAddress())).wait();
  await (await certificates.grantRole(await certificates.RETIREMENT_ROLE(), await retirement.getAddress())).wait();
  await (await carbon.grantRole(await carbon.AUDITOR_ROLE(), auditor.address)).wait();
  await (await carbon.grantRole(await carbon.MARKET_ROLE(), await market.getAddress())).wait();
  await (await carbon.grantRole(await carbon.RETIREMENT_ROLE(), await retirement.getAddress())).wait();
  await (await market.grantRole(await market.OPERATOR_ROLE(), await governor.getAddress())).wait();
  await (await p2p.grantRole(await p2p.OPERATOR_ROLE(), await governor.getAddress())).wait();
  await (await oracle.postPrice(await aeds.getAddress(), ethers.parseEther("0.5"))).wait();

  async function fund(who, amount, to) {
    await (await aeds.mint(who.address, amount)).wait();
    await (await aeds.connect(who).approve(to, amount)).wait();
  }

  console.log("== meters + certificates ==");
  await (await registry.connect(producer).register(1, 784)).wait();
  await (await registry.connect(consumer).register(2, 784)).wait();
  await (await registry.connect(auditor).register(3, 784)).wait();
  await (await meters.connect(producer).registerMeter(ethers.id("meter-001"), 10000n)).wait();
  await (await meters.connect(auditor).attestProduction(0, 5000n)).wait();
  await (await certificates.connect(auditor).mint(0, 5n)).wait();
  check("5 RECs minted", (await certificates.balanceOf(producer.address)) === 5n);

  console.log("== market ==");
  await (await market.connect(producer).placeOrder(0, ethers.parseEther("40"), 3n)).wait();
  await fund(consumer, ethers.parseEther("1000"), await market.getAddress());
  await (await market.connect(consumer).fill(0, 2n)).wait();
  check("2 RECs bought", (await certificates.balanceOf(consumer.address)) === 2n);

  console.log("== retirement ==");
  await (await retirement.connect(consumer).retireRec(1n, "2026 green claim")).wait();
  check("1 REC retired", (await retirement.retiredRec(consumer.address)) === 1n);
  check("retirement burned it", (await certificates.balanceOf(consumer.address)) === 1n);

  console.log("== P2P energy ==");
  await (await p2p.connect(producer).postOffer(ethers.parseEther("1000"), ethers.parseEther("0.5"))).wait();
  await fund(consumer, ethers.parseEther("1000"), await p2p.getAddress());
  await (await p2p.connect(consumer).buy(0, ethers.parseEther("100"))).wait();
  check("100 kWh consumed", (await p2p.consumedKwh(consumer.address)) === ethers.parseEther("100"));

  console.log("== governance ==");
  const calldata = p2p.interface.encodeFunctionData("setFee", [50]);
  await (await governor.connect(funder).propose(await p2p.getAddress(), 0n, calldata, "Raise P2P fee to 0.5%")).wait();
  await provider.send("evm_increaseTime", [3 * 86400]);
  await provider.send("evm_mine", []);
  await (await funder.sendTransaction({ to: funderAddr, value: 0n })).wait();
  await (await governor.connect(producer).vote(0, true)).wait();
  await provider.send("evm_increaseTime", [10 * 86400]);
  await provider.send("evm_mine", []);
  await (await funder.sendTransaction({ to: funderAddr, value: 0n })).wait();
  check("proposal succeeded", Number(await governor.state(0)) === 3);
  await (await governor.execute(0)).wait();
  check("P2P fee 0.5%", (await p2p.feeBps()) === 50n);

  console.log("\n" + (failed === 0 ? "SMOKE TEST PASSED" : "SMOKE TEST FAILED") + " — " + passed + " passed, " + failed + " failed");
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
