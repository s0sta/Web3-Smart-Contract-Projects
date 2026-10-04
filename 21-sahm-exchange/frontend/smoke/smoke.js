/* ============================================================
   Sahm dApp — end-to-end smoke test (Node, no npm)
   Deploys the FULL exchange and walks the trading cycle:
   margin deposit → order book ask + fill → AMM swap → leveraged
   long → profit close → governance proposal.

     1. anvil
     2. forge build
     3. COLLATERAL=0x… node smoke/smoke.js
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

  const trader = ethers.Wallet.createRandom().connect(provider);
  const taker = ethers.Wallet.createRandom().connect(provider);
  const lp = ethers.Wallet.createRandom().connect(provider);
  for (const w of [trader, taker, lp]) {
    await (await funder.sendTransaction({ to: w.address, value: ethers.parseEther("0.5") })).wait();
  }

  console.log("== deploy the exchange ==");
  const stable = await new ethers.ContractFactory(art("MockStable").abi, art("MockStable").bytecode, funder).deploy();
  await stable.waitForDeployment();
  const compliance = await new ethers.ContractFactory(art("SahmCompliance").abi, art("SahmCompliance").bytecode, funder).deploy([funderAddr]);
  await compliance.waitForDeployment();
  const oracle = await new ethers.ContractFactory(art("SahmOracle").abi, art("SahmOracle").bytecode, funder).deploy(3600, 86400);
  await oracle.waitForDeployment();
  const collateral = await new ethers.ContractFactory(art("SahmCollateral").abi, art("SahmCollateral").bytecode, funder)
    .deploy(await stable.getAddress());
  await collateral.waitForDeployment();
  const treasury = await new ethers.ContractFactory(art("SahmTreasury").abi, art("SahmTreasury").bytecode, funder)
    .deploy(await stable.getAddress(), 2000);
  await treasury.waitForDeployment();
  const risk = await new ethers.ContractFactory(art("SahmRisk").abi, art("SahmRisk").bytecode, funder)
    .deploy(await oracle.getAddress());
  await risk.waitForDeployment();
  const book = await new ethers.ContractFactory(art("SahmOrderBook").abi, art("SahmOrderBook").bytecode, funder)
    .deploy(await collateral.getAddress(), await compliance.getAddress(), await risk.getAddress(), await treasury.getAddress(), await stable.getAddress());
  await book.waitForDeployment();
  const amm = await new ethers.ContractFactory(art("SahmAMM").abi, art("SahmAMM").bytecode, funder)
    .deploy(await compliance.getAddress(), await risk.getAddress(), await treasury.getAddress(), await stable.getAddress());
  await amm.waitForDeployment();
  const margin = await new ethers.ContractFactory(art("SahmMargin").abi, art("SahmMargin").bytecode, funder)
    .deploy(await collateral.getAddress(), await oracle.getAddress(), await compliance.getAddress(), await risk.getAddress());
  await margin.waitForDeployment();
  const insurance = await new ethers.ContractFactory(art("SahmInsuranceFund").abi, art("SahmInsuranceFund").bytecode, funder)
    .deploy(await stable.getAddress());
  await insurance.waitForDeployment();
  const governor = await new ethers.ContractFactory(art("SahmGovernor").abi, art("SahmGovernor").bytecode, funder)
    .deploy(await amm.getAddress(), await margin.getAddress(), await book.getAddress(), await risk.getAddress(), await treasury.getAddress(), 1000);
  await governor.waitForDeployment();

  // wiring
  await (await collateral.grantRole(await collateral.ORDERBOOK_ROLE(), await book.getAddress())).wait();
  await (await collateral.grantRole(await collateral.MARGIN_ROLE(), await margin.getAddress())).wait();
  await (await risk.grantRole(await risk.VENUE_ROLE(), await book.getAddress())).wait();
  await (await risk.grantRole(await risk.VENUE_ROLE(), await amm.getAddress())).wait();
  await (await book.grantRole(await book.OPERATOR_ROLE(), await governor.getAddress())).wait();
  await (await amm.grantRole(await amm.OPERATOR_ROLE(), await governor.getAddress())).wait();
  await (await margin.grantRole(await margin.OPERATOR_ROLE(), await governor.getAddress())).wait();
  await (await treasury.grantRole(await treasury.OPERATOR_ROLE(), await governor.getAddress())).wait();
  await (await risk.grantRole(await risk.OPERATOR_ROLE(), await governor.getAddress())).wait();
  await (await risk.setMarket(await stable.getAddress(), ethers.parseEther("1000000"), ethers.parseEther("5000000"), 1000)).wait();
  await (await oracle.postPrice(await stable.getAddress(), ethers.parseEther("2000"))).wait();
  for (const w of [trader, taker, lp]) {
    await (await compliance.setKyc(w.address, 1)).wait();
  }
  const poolId = await (await amm.listPool(await stable.getAddress())).wait().then(() => 0n);

  async function fund(who, amount, to) {
    await (await stable.mint(who.address, amount)).wait();
    await (await stable.connect(who).approve(to, amount)).wait();
  }

  console.log("== margin + order book ==");
  await fund(trader, ethers.parseEther("200000"), await collateral.getAddress());
  await (await collateral.connect(trader).deposit(ethers.parseEther("100000"))).wait();
  await fund(trader, ethers.parseEther("50000"), await book.getAddress());
  await (await book.connect(trader).placeAsk(await stable.getAddress(), ethers.parseEther("2000"), ethers.parseEther("4"))).wait();
  await fund(taker, ethers.parseEther("20000"), await book.getAddress());
  const takerBefore = await stable.balanceOf(taker.address);
  await (await book.connect(taker).buy(0, ethers.parseEther("4"))).wait();
  check("ask filled, taker net 8,012", (await stable.balanceOf(taker.address)) === takerBefore - ethers.parseEther("8012"));
  check("fees in treasury (16+8)", (await treasury.totalFeesCollected()) === ethers.parseEther("24"));

  console.log("== AMM ==");
  await fund(lp, ethers.parseEther("100000"), await amm.getAddress());
  await (await amm.connect(lp).addLiquidity(poolId, ethers.parseEther("10"), ethers.parseEther("20000"))).wait();
  await fund(trader, ethers.parseEther("10000"), await amm.getAddress());
  const tBefore = await stable.balanceOf(trader.address);
  await (await amm.connect(trader).swapQuoteForToken(poolId, ethers.parseEther("1000"), 0n)).wait();
  check("swap executed", (await stable.balanceOf(trader.address)) < tBefore);

  console.log("== leveraged long ==");
  await (await margin.connect(trader).openPosition(await stable.getAddress(), 1, ethers.parseEther("5000"), 200n)).wait();
  check("margin locked", (await collateral.lockedMargin(trader.address)) === ethers.parseEther("5000"));
  await provider.send("evm_increaseTime", [7202]);
  await provider.send("evm_mine", []);
  await (await funder.sendTransaction({ to: funderAddr, value: 0n })).wait();
  await (await oracle.postPrice(await stable.getAddress(), ethers.parseEther("2200"))).wait();
  await (await margin.connect(trader).closePosition(0)).wait();
  check("position closed", (await margin.positions(0)).open === false);

  console.log("== governance ==");
  const calldata = amm.interface.encodeFunctionData("setFees", [50, 2000]);
  await (await governor.connect(lp).propose(await amm.getAddress(), 0n, calldata, "Raise AMM fee to 0.5%")).wait();
  await provider.send("evm_increaseTime", [3 * 86400]);
  await provider.send("evm_mine", []);
  await (await funder.sendTransaction({ to: funderAddr, value: 0n })).wait();
  await (await governor.connect(lp).vote(0, true)).wait();
  await provider.send("evm_increaseTime", [10 * 86400]);
  await provider.send("evm_mine", []);
  await (await funder.sendTransaction({ to: funderAddr, value: 0n })).wait();
  check("proposal succeeded", Number(await governor.state(0)) === 3);
  await (await governor.execute(0)).wait();
  check("AMM fee 0.5%", (await amm.feeBps()) === 50n);

  console.log("\n" + (failed === 0 ? "SMOKE TEST PASSED" : "SMOKE TEST FAILED") + " — " + passed + " passed, " + failed + " failed");
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
