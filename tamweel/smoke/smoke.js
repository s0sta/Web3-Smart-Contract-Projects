/* ============================================================
   Tamweel dApp — end-to-end smoke test (Node, no npm)
   Deploys the FULL bank and walks the credit cycle:
   deposit → supply → borrow → repay → liquidation auction →
   installment loan → governance proposal.

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
  const art = (name) => JSON.parse(fs.readFileSync(path.join(__dirname, "..", "..", "out", name + ".sol", name + ".json"), "utf8"));

  const provider = new ethers.JsonRpcProvider(RPC);
  const funder = new ethers.Wallet(FUNDER_KEY, provider);
  const funderAddr = funder.address;

  const committee = ethers.Wallet.createRandom().connect(provider);
  const depositor = ethers.Wallet.createRandom().connect(provider);
  const borrower = ethers.Wallet.createRandom().connect(provider);
  const liquidator = ethers.Wallet.createRandom().connect(provider);
  for (const w of [committee, depositor, borrower, liquidator]) {
    await (await funder.sendTransaction({ to: w.address, value: ethers.parseEther("0.5") })).wait();
  }

  console.log("== deploy the bank ==");
  const stable = await new ethers.ContractFactory(art("MockStable").abi, art("MockStable").bytecode, funder).deploy();
  await stable.waitForDeployment();
  const compliance = await new ethers.ContractFactory(art("TamweelCompliance").abi, art("TamweelCompliance").bytecode, funder).deploy([committee.address]);
  await compliance.waitForDeployment();
  const oracle = await new ethers.ContractFactory(art("TamweelOracle").abi, art("TamweelOracle").bytecode, funder).deploy(3600, 86400);
  await oracle.waitForDeployment();
  const vault = await new ethers.ContractFactory(art("TamweelVault").abi, art("TamweelVault").bytecode, funder)
    .deploy(await stable.getAddress(), 500);
  await vault.waitForDeployment();
  const rateModel = await new ethers.ContractFactory(art("TamweelRateModel").abi, art("TamweelRateModel").bytecode, funder)
    .deploy(BigInt(3e16) / 31536000n, BigInt(12e16) / 31536000n, BigInt(60e16) / 31536000n, 8000, 1000);
  await rateModel.waitForDeployment();
  const collateral = await new ethers.ContractFactory(art("TamweelCollateral").abi, art("TamweelCollateral").bytecode, funder)
    .deploy(await stable.getAddress());
  await collateral.waitForDeployment();
  const markets = await new ethers.ContractFactory(art("TamweelMarkets").abi, art("TamweelMarkets").bytecode, funder)
    .deploy(await vault.getAddress(), await oracle.getAddress(), await rateModel.getAddress(), await compliance.getAddress(), await collateral.getAddress(), await stable.getAddress());
  await markets.waitForDeployment();
  const loans = await new ethers.ContractFactory(art("TamweelLoans").abi, art("TamweelLoans").bytecode, funder)
    .deploy(await compliance.getAddress(), await vault.getAddress(), await stable.getAddress(), funderAddr, 500, 500, 200, 2);
  await loans.waitForDeployment();
  const insurance = await new ethers.ContractFactory(art("TamweelInsuranceFund").abi, art("TamweelInsuranceFund").bytecode, funder)
    .deploy(await vault.getAddress(), await stable.getAddress());
  await insurance.waitForDeployment();
  const governor = await new ethers.ContractFactory(art("TamweelGovernor").abi, art("TamweelGovernor").bytecode, funder)
    .deploy(await vault.getAddress(), await rateModel.getAddress(), await markets.getAddress(), await loans.getAddress(), await compliance.getAddress(), 1000);
  await governor.waitForDeployment();

  // wiring
  await (await vault.grantRole(await vault.MARKETS_ROLE(), await markets.getAddress())).wait();
  await (await vault.grantRole(await vault.MARKETS_ROLE(), await loans.getAddress())).wait();
  await (await vault.grantRole(await vault.INSURANCE_ROLE(), await insurance.getAddress())).wait();
  await (await collateral.grantRole(await collateral.MARKETS_ROLE(), await markets.getAddress())).wait();
  await (await loans.grantRole(await loans.COMMITTEE_ROLE(), committee.address)).wait();
  await (await loans.grantRole(await loans.DEFAULT_ADMIN_ROLE(), await governor.getAddress())).wait();
  await (await compliance.connect(committee).setKyc(depositor.address, 1)).wait();
  await (await compliance.connect(committee).setKyc(borrower.address, 1)).wait();
  await (await compliance.connect(committee).setCreditScore(borrower.address, 850)).wait();
  await (await compliance.connect(committee).setKyc(liquidator.address, 1)).wait();
  await (await compliance.connect(committee).setKyc(await markets.getAddress(), 1)).wait();
  await (await markets.listMarket(await stable.getAddress(), 7000, 8000, 500)).wait();
  await (await oracle.postPrice(await stable.getAddress(), ethers.parseEther("2000"))).wait();

  async function fund(who, amount, to) {
    await (await stable.mint(who.address, amount)).wait();
    await (await stable.connect(who).approve(to, amount)).wait();
  }

  console.log("== deposits ==");
  await fund(depositor, ethers.parseEther("100000"), await vault.getAddress());
  await (await vault.connect(depositor).deposit(ethers.parseEther("100000"))).wait();
  check("vault assets 100k", (await vault.totalAssets()) === ethers.parseEther("100000"));

  console.log("== collateralized credit ==");
  await fund(borrower, ethers.parseEther("50000"), await markets.getAddress());
  await (await markets.connect(borrower).supply(0, ethers.parseEther("10"))).wait();
  await (await markets.connect(borrower).borrow(0, ethers.parseEther("14000"))).wait();
  check("debt 14k", (await markets.debtOf(0, borrower.address)) >= ethers.parseEther("14000"));
  const health = await markets.healthFactor(0, borrower.address);
  check("healthy", health >= 10n ** 18n);

  console.log("== liquidation + auction ==");
  await (await oracle.postPrice(await stable.getAddress(), ethers.parseEther("1500"))).wait();
  await provider.send("evm_increaseTime", [7202]);
  await provider.send("evm_mine", []);
  await (await funder.sendTransaction({ to: funderAddr, value: 0n })).wait();
  await (await oracle.postPrice(await stable.getAddress(), ethers.parseEther("1500"))).wait();
  await provider.send("evm_increaseTime", [7202]);
  await provider.send("evm_mine", []);
  await (await funder.sendTransaction({ to: funderAddr, value: 0n })).wait();
  await fund(liquidator, ethers.parseEther("30000"), await markets.getAddress());
  console.log('  [debug] price:', (await oracle.price(await stable.getAddress())).toString());
  console.log('  [debug] health:', (await markets.healthFactor(0, borrower.address)).toString());
  console.log('  [debug] debt:', (await markets.debtOf(0, borrower.address)).toString());
  await (await markets.connect(liquidator).liquidate(0, borrower.address)).wait();
  check("position liquidated", (await markets.collateral(0, borrower.address)) === 0n);
  await fund(borrower, ethers.parseEther("40000"), await collateral.getAddress());
  await (await collateral.connect(borrower).bid(0)).wait();
  const auction = await collateral.auctions(0);
  check("auction settled", auction.settled === true);

  console.log("== installment loan ==");
  await fund(borrower, ethers.parseEther("20000"), await loans.getAddress());
  await (await loans.connect(borrower).requestLoan(ethers.parseEther("10000"), 10n, 2592000n, "working capital")).wait();
  await (await loans.connect(committee).approveLoan(0)).wait();
  await (await loans.disburse(0)).wait();
  check("loan disbursed", (await stable.balanceOf(borrower.address)) > ethers.parseEther("0"));

  console.log("== governance ==");
  const calldata = loans.interface.encodeFunctionData("setLoanInterestBps", [600]);
  await (await governor.connect(depositor).propose(await loans.getAddress(), 0n, calldata, "Raise loan rate to 6%")).wait();
  await provider.send("evm_increaseTime", [3 * 86400]);
  await provider.send("evm_mine", []);
  await (await funder.sendTransaction({ to: funderAddr, value: 0n })).wait();
  await (await governor.connect(depositor).vote(0, true)).wait();
  await provider.send("evm_increaseTime", [10 * 86400]);
  await provider.send("evm_mine", []);
  await (await funder.sendTransaction({ to: funderAddr, value: 0n })).wait();
  check("proposal succeeded", Number(await governor.state(0)) === 3);
  await (await governor.execute(0)).wait();
  check("loan rate 6%", (await loans.loanInterestBps()) === 600n);

  console.log("\n" + (failed === 0 ? "SMOKE TEST PASSED" : "SMOKE TEST FAILED") + " — " + passed + " passed, " + failed + " failed");
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
