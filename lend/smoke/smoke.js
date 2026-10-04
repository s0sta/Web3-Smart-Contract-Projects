/* ============================================================
   LendVault dApp — end-to-end smoke test (Node, no npm)
   Verifies the EXACT bundles the site uses (ethers v6 UMD + the
   shipped js/abi.js) against any deployed LendVault.

     1. anvil                        (terminal 1)
     2. forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
     3. VAULT=0x… node smoke/smoke.js
   ============================================================ */

const fs = require("fs");
const os = require("os");
const path = require("path");

const ETHER_VERSION = "6.13.4";
const ETHER_CDN = `https://cdn.jsdelivr.net/npm/ethers@${ETHER_VERSION}/dist/ethers.umd.min.js`;

const RPC = process.env.RPC || "http://127.0.0.1:8545";
const VAULT = process.env.VAULT;
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
  if (!VAULT) {
    console.error("Usage: VAULT=0x… node smoke/smoke.js");
    process.exit(2);
  }
  const ethers = await loadEthers();

  global.window = {};
  require(path.join(__dirname, "..", "js", "abi.js"));
  const ABI_V = window.LEND_VAULT_ABI;
  const ABI_S = window.STABLE_ABI;

  const provider = new ethers.JsonRpcProvider(RPC);
  const funder = new ethers.Wallet(FUNDER_KEY, provider);
  const ifaceV = new ethers.Interface(ABI_V);

  const vault = new ethers.Contract(VAULT, ABI_V, funder);
  const stable = new ethers.Contract(await vault.stable(), ABI_S, funder);

  // fresh borrower + liquidator per run
  const bor = ethers.Wallet.createRandom().connect(provider);
  const liq = ethers.Wallet.createRandom().connect(provider);
  for (const w of [bor, liq]) {
    await (await funder.sendTransaction({ to: w.address, value: ethers.parseEther("20") })).wait();
  }

  console.log("== reads ==");
  check("owner correct", (await vault.owner()).toLowerCase() === funder.address.toLowerCase());
  check("not paused", (await vault.paused()) === false);
  check("LTV 66%", (await vault.LTV_BPS()) === 6600n);
  check("APR 10%", (await vault.ANNUAL_RATE_BPS()) === 1000n);

  console.log("== deposit & borrow ==");
  const totalC0 = await vault.totalCollateral();
  await (await vault.connect(bor).deposit({ value: ethers.parseEther("10") })).wait();
  check("collateral 10 ETH", (await vault.collateral(bor.address)) === ethers.parseEther("10"));
  check("totalCollateral +10", (await vault.totalCollateral()) === totalC0 + ethers.parseEther("10"));

  const limit = (ethers.parseEther("10") * 2000n * 6600n) / 10000n; // 13,200
  const maxB = await vault.maxBorrow(bor.address);
  check("maxBorrow == 13,200", maxB === limit, maxB.toString());

  await (await vault.connect(bor).borrow(ethers.parseEther("10000"))).wait();
  check("debt 10,000", (await vault.debt(bor.address)) === ethers.parseEther("10000"));
  check("borrower received 10,000 stable", (await stable.balanceOf(bor.address)) === ethers.parseEther("10000"));

  const hf = await vault.healthFactor(bor.address);
  // 10 ETH × 2000 × 0.8 / 10,000 = 1.6
  check("health factor ≈ 1.6", hf >= ethers.parseEther("1.59") && hf <= ethers.parseEther("1.61"), ethers.formatUnits(hf));

  console.log("== interest accrual ==");
  await provider.send("evm_increaseTime", [86400]);
  await provider.send("evm_mine", []);
  await (await funder.sendTransaction({ to: funder.address, value: 0n })).wait(); // anchor committed block
  const debtNow = await vault.currentDebt(bor.address);
  check("interest accrued after 1 day", debtNow > ethers.parseEther("10000"), debtNow.toString());

  console.log("== repay ==");
  await (await stable.connect(bor).approve(VAULT, ethers.parseEther("100000"))).wait();
  await (await vault.connect(bor).repay(ethers.parseEther("5000"))).wait();
  check("debt reduced", (await vault.currentDebt(bor.address)) < debtNow - ethers.parseEther("4990"));

  console.log("== withdraw guard ==");
  // remaining collateral must cover debt at LTV: try to withdraw everything → should revert
  try {
    await vault.connect(bor).withdraw(ethers.parseEther("9"));
    check("over-withdraw reverts", false, "should have reverted");
  } catch (err) {
    const e = ifaceV.parseError(err.data);
    check("BorrowLimitExceeded decoded", e && e.name === "BorrowLimitExceeded", e && e.name);
  }

  console.log("== liquidation (interest pushes past threshold) ==");
  const bor2 = ethers.Wallet.createRandom().connect(provider);
  await (await funder.sendTransaction({ to: bor2.address, value: ethers.parseEther("5") })).wait();
  await (await vault.connect(bor2).deposit({ value: ethers.parseEther("1") })).wait();
  await (await vault.connect(bor2).borrow(ethers.parseEther("1320"))).wait(); // max at 66%
  check("bor2 not liquidatable yet", (await vault.liquidatable(bor2.address)) === false);
  // 1320 → threshold 1600: needs +21.2% interest ≈ 2.12 years at 10% APR
  await provider.send("evm_increaseTime", [Math.floor(2.2 * 365 * 86400)]);
  await provider.send("evm_mine", []);
  await (await funder.sendTransaction({ to: funder.address, value: 0n })).wait();
  check("bor2 liquidatable after interest", (await vault.liquidatable(bor2.address)) === true);

  // liquidator: deposit, borrow 660, approve, liquidate
  await (await vault.connect(liq).deposit({ value: ethers.parseEther("1") })).wait();
  await (await vault.connect(liq).borrow(ethers.parseEther("660"))).wait();
  await (await stable.connect(liq).approve(VAULT, ethers.parseEther("660"))).wait();
  const liqBalBefore = await provider.getBalance(liq.address);
  const bor2DebtBefore = await vault.currentDebt(bor2.address);
  const rc = await (await vault.connect(liq).liquidate(bor2.address, ethers.parseEther("660"))).wait();
  const liqEv = rc.logs.map((l) => { try { return ifaceV.parseLog(l); } catch { return null; } }).find((l) => l && l.name === "Liquidated");
  check("Liquidated event", !!liqEv);
  // seized ETH is sent to the liquidator's WALLET (minus gas)
  const seize = liqEv.args.collateralSeized;
  check("liquidator received seized ETH", (await provider.getBalance(liq.address)) > liqBalBefore + seize - ethers.parseEther("0.01"));
  const debtDelta = bor2DebtBefore - (await vault.currentDebt(bor2.address));
  check("bor2 debt reduced by ≈660", debtDelta > ethers.parseEther("659") && debtDelta <= ethers.parseEther("661"), debtDelta.toString());

  console.log("== pause guard (emergency brake) ==");
  await (await vault.connect(funder).setPaused(true)).wait();
  check("paused", (await vault.paused()) === true);
  try {
    await vault.connect(bor).deposit({ value: ethers.parseEther("1") });
    check("deposit while paused reverts", false, "should have reverted");
  } catch (err) {
    const e = ifaceV.parseError(err.data);
    check("VaultPaused decoded", e && e.name === "VaultPaused", e && e.name);
  }
  // withdrawals stay open while paused
  await (await vault.connect(bor).withdraw(ethers.parseEther("1"))).wait();
  check("withdraw works while paused", (await vault.collateral(bor.address)) === ethers.parseEther("9"));
  await (await vault.connect(funder).setPaused(false)).wait();
  check("unpaused", (await vault.paused()) === false);

  console.log("== error decoding (same as the dApp) ==");
  try {
    await vault.connect(bor).repay(ethers.parseEther("999999"));
    check("over-repay reverts", false, "should have reverted");
  } catch (err) {
    const e = ifaceV.parseError(err.data);
    check("RepayExceedsDebt decoded", e && e.name === "RepayExceedsDebt", e && e.name);
  }
  try {
    await vault.connect(bor).borrow(ethers.parseEther("999999"));
    check("over-borrow reverts", false, "should have reverted");
  } catch (err) {
    const e = ifaceV.parseError(err.data);
    check("BorrowLimitExceeded decoded", e && e.name === "BorrowLimitExceeded", e && e.name);
  }

  console.log("== event feed (the dApp's getLogs flow) ==");
  const latest = await provider.getBlockNumber();
  const logs = await provider.getLogs({ address: VAULT, fromBlock: 0, toBlock: latest });
  const decoded = logs.map((l) => { try { return ifaceV.parseLog(l); } catch { return null; } }).filter(Boolean);
  const names = decoded.map((d) => d.name);
  for (const n of ["Deposited", "Borrowed", "Repaid", "Withdrawn", "Liquidated", "Paused", "Unpaused"]) {
    check(n + " present", names.includes(n));
  }

  console.log("\n" + (failed === 0 ? "SMOKE TEST PASSED" : "SMOKE TEST FAILED") + " — " + passed + " passed, " + failed + " failed");
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
