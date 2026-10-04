/* ============================================================
   Rahala dApp — end-to-end smoke test (Node, no npm)
   Deploys the FULL network and walks the money-movement cycle:
   credit → escrowed payment → FX conversion → invoice factoring →
   netting → dispute arbitration → governance.

     1. anvil
     2. forge build
     3. ACCOUNTS=0x… node smoke/smoke.js
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

  const alice = ethers.Wallet.createRandom().connect(provider);
  const bob = ethers.Wallet.createRandom().connect(provider);
  const financier = ethers.Wallet.createRandom().connect(provider);
  const arbiter = ethers.Wallet.createRandom().connect(provider);
  for (const w of [alice, bob, financier, arbiter]) {
    await (await funder.sendTransaction({ to: w.address, value: ethers.parseEther("0.5") })).wait();
  }

  console.log("== deploy the network ==");
  const aeds = await new ethers.ContractFactory(art("RahalaStable").abi, art("RahalaStable").bytecode, funder)
    .deploy("Rahala AED Stable", "AED-S");
  await aeds.waitForDeployment();
  const usd = await new ethers.ContractFactory(art("MockStable").abi, art("MockStable").bytecode, funder).deploy();
  await usd.waitForDeployment();
  const compliance = await new ethers.ContractFactory(art("RahalaCompliance").abi, art("RahalaCompliance").bytecode, funder)
    .deploy([funderAddr]);
  await compliance.waitForDeployment();
  const oracle = await new ethers.ContractFactory(art("RahalaOracle").abi, art("RahalaOracle").bytecode, funder)
    .deploy(3600, 86400);
  await oracle.waitForDeployment();
  const accounts = await new ethers.ContractFactory(art("RahalaAccounts").abi, art("RahalaAccounts").bytecode, funder)
    .deploy(await aeds.getAddress());
  await accounts.waitForDeployment();
  const treasury = await new ethers.ContractFactory(art("RahalaTreasury").abi, art("RahalaTreasury").bytecode, funder)
    .deploy(await aeds.getAddress(), 2000);
  await treasury.waitForDeployment();
  const fx = await new ethers.ContractFactory(art("RahalaFX").abi, art("RahalaFX").bytecode, funder)
    .deploy(await aeds.getAddress(), await oracle.getAddress(), await compliance.getAddress(), await treasury.getAddress());
  await fx.waitForDeployment();
  const escrow = await new ethers.ContractFactory(art("RahalaEscrow").abi, art("RahalaEscrow").bytecode, funder)
    .deploy(await aeds.getAddress(), await compliance.getAddress(), await treasury.getAddress());
  await escrow.waitForDeployment();
  const invoices = await new ethers.ContractFactory(art("RahalaInvoices").abi, art("RahalaInvoices").bytecode, funder)
    .deploy(await aeds.getAddress(), await compliance.getAddress());
  await invoices.waitForDeployment();
  const netting = await new ethers.ContractFactory(art("RahalaSettlement").abi, art("RahalaSettlement").bytecode, funder)
    .deploy(await aeds.getAddress());
  await netting.waitForDeployment();
  const disputes = await new ethers.ContractFactory(art("RahalaDisputes").abi, art("RahalaDisputes").bytecode, funder).deploy();
  await disputes.waitForDeployment();
  const governor = await new ethers.ContractFactory(art("RahalaGovernor").abi, art("RahalaGovernor").bytecode, funder)
    .deploy(await accounts.getAddress(), await fx.getAddress(), await escrow.getAddress(), await invoices.getAddress(), await netting.getAddress(), await treasury.getAddress(), await compliance.getAddress(), await oracle.getAddress(), 1000);
  await governor.waitForDeployment();

  // wiring
  await (await escrow.grantRole(await escrow.DISPUTES_ROLE(), await disputes.getAddress())).wait();
  await (await disputes.grantRole(await disputes.ARBITER_ROLE(), arbiter.address)).wait();
  await (await aeds.grantRole(await aeds.ISSUER_ROLE(), await accounts.getAddress())).wait();
  await (await escrow.grantRole(await escrow.DEFAULT_ADMIN_ROLE(), await governor.getAddress())).wait();
  await (await compliance.setRegionAllowed(784, true)).wait();
  await (await compliance.setRegionAllowed(840, true)).wait();
  for (const w of [alice, bob, financier]) {
    await (await compliance.setKyc(w.address, 1)).wait();
    await (await compliance.setHomeRegion(w.address, 784)).wait();
    await (await accounts.credit(w.address, ethers.parseEther("100000"))).wait();
  }
  await (await fx.listCurrency(await usd.getAddress(), "USD", 840)).wait();
  await (await oracle.postRate(await usd.getAddress(), ethers.parseEther("3.67"))).wait();
  await (await usd.mint(funderAddr, ethers.parseEther("1000000"))).wait();
  await (await usd.approve(await fx.getAddress(), ethers.parseEther("1000000"))).wait();
  await (await fx.addLiquidity(await usd.getAddress(), ethers.parseEther("1000000"))).wait();
  await (await aeds.mint(await fx.getAddress(), ethers.parseEther("1000000"))).wait();

  console.log("== escrowed payment ==");
  await (await aeds.connect(alice).approve(await escrow.getAddress(), ethers.parseEther("50000"))).wait();
  await (await escrow.connect(alice).createPayment(bob.address, ethers.parseEther("10000"), 0, 0n, 0n, 784, ethers.id("memo"))).wait();
  check("escrow locked", (await escrow.totalEscrowed()) === ethers.parseEther("10000"));
  const bobBefore = await aeds.balanceOf(bob.address);
  await (await escrow.connect(bob).claim(0)).wait();
  check("bob received 9,975 (0.25% fee)", (await aeds.balanceOf(bob.address)) - bobBefore === ethers.parseEther("9975"));

  console.log("== FX conversion ==");
  await (await aeds.connect(alice).approve(await fx.getAddress(), ethers.parseEther("50000"))).wait();
  await (await fx.connect(alice).convertTo(await usd.getAddress(), ethers.parseEther("3670"), 0n)).wait();
  check("USD received ~993", (await usd.balanceOf(alice.address)) === ethers.parseEther("993"));

  console.log("== invoice factoring ==");
  await (await invoices.connect(bob).registerInvoice(alice.address, ethers.parseEther("10000"), BigInt(Math.floor(Date.now() / 1000) + 86400), 784, "goods")).wait();
  await (await aeds.connect(financier).approve(await invoices.getAddress(), ethers.parseEther("9700"))).wait();
  await (await invoices.connect(financier).factor(0)).wait();
  const inv = await invoices.invoices(0);
  check("factored at 3% discount", inv.factoredAmount === ethers.parseEther("9700"));

  console.log("== netting ==");
  await (await netting.openBatch()).wait();
  await (await netting.addObligation(alice.address, bob.address, ethers.parseEther("5000"))).wait();
  await (await netting.addObligation(bob.address, alice.address, ethers.parseEther("3000"))).wait();
  await (await aeds.connect(alice).approve(await netting.getAddress(), ethers.parseEther("5000"))).wait();
  await (await netting.settleBatch([alice.address], [ethers.parseEther("2000")])).wait();
  check("netted 2,000", (await netting.nettedTotal()) === ethers.parseEther("2000"));

  console.log("== governance ==");
  const calldata = escrow.interface.encodeFunctionData("setEscrowFee", [50]);
  await (await governor.connect(alice).propose(await escrow.getAddress(), 0n, calldata, "Raise escrow fee to 0.5%")).wait();
  await provider.send("evm_increaseTime", [3 * 86400]);
  await provider.send("evm_mine", []);
  await (await funder.sendTransaction({ to: funderAddr, value: 0n })).wait();
  await (await governor.connect(alice).vote(0, true)).wait();
  await provider.send("evm_increaseTime", [10 * 86400]);
  await provider.send("evm_mine", []);
  await (await funder.sendTransaction({ to: funderAddr, value: 0n })).wait();
  check("proposal succeeded", Number(await governor.state(0)) === 3);
  await (await governor.execute(0)).wait();
  check("escrow fee 0.5%", (await escrow.escrowFeeBps()) === 50n);

  console.log("\n" + (failed === 0 ? "SMOKE TEST PASSED" : "SMOKE TEST FAILED") + " — " + passed + " passed, " + failed + " failed");
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
