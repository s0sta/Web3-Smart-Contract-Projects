/* ============================================================
   StakeVault dApp — end-to-end smoke test (Node, no npm)
   Verifies the EXACT bundles the site uses (ethers v6 UMD + the
   shipped js/abi.js) against any deployed StakeVault:

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
const OWNER_KEY = process.env.OWNER_KEY || "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"; // anvil #0
const USER_KEY = process.env.USER_KEY || "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"; // anvil #1

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
  const ABI_V = window.STAKE_VAULT_ABI;
  const ABI_T = window.IERC20_ABI;

  const provider = new ethers.JsonRpcProvider(RPC);
  const owner = new ethers.Wallet(OWNER_KEY, provider);
  const user = new ethers.Wallet(USER_KEY, provider);

  const vault = new ethers.Contract(VAULT, ABI_V, owner);
  const iface = new ethers.Interface(ABI_V);
  const staking = new ethers.Contract(await vault.stakingToken(), ABI_T, owner);
  const reward = new ethers.Contract(await vault.rewardsToken(), ABI_T, owner);

  console.log("== reads ==");
  const rate = await vault.rewardRate();
  check("reward rate > 0", rate > 0n);
  check("owner correct", (await vault.owner()).toLowerCase() === owner.address.toLowerCase());
  const finish = Number(await vault.periodFinish());
  check("period in future", finish > Math.floor(Date.now() / 1000));

  console.log("== stake ==");
  await (await staking.mint(user.address, ethers.parseEther("1000"))).wait();
  await (await staking.connect(user).approve(VAULT, ethers.MaxUint256)).wait();
  const totalBefore = await vault.totalSupply();
  await (await vault.connect(user).stake(ethers.parseEther("1000"))).wait();
  check("total +1000", (await vault.totalSupply()) === totalBefore + ethers.parseEther("1000"));
  check("user stake 1000", (await vault.balanceOf(user.address)) === ethers.parseEther("1000"));

  console.log("== time travel & earn ==");
  await provider.send("evm_increaseTime", [86400]); // 1 day
  await provider.send("evm_mine", []);
  const earned = await vault.earned(user.address);
  // sole staker → full rate for 1 day (±5% for anvil timestamp drift)
  const lo = (rate * 86400n * 95n) / 100n;
  const hi = (rate * 86400n * 105n) / 100n;
  check("earned ≈ rate×1d", earned >= lo && earned <= hi);

  console.log("== claim ==");
  const rBefore = await reward.balanceOf(user.address);
  await (await vault.connect(user).getReward()).wait();
  check("reward paid", (await reward.balanceOf(user.address)) === rBefore + earned);

  console.log("== withdraw + exit ==");
  await (await vault.connect(user).withdraw(ethers.parseEther("400"))).wait();
  check("stake 600 after withdraw", (await vault.balanceOf(user.address)) === ethers.parseEther("600"));
  await (await vault.connect(user).exitAll()).wait();
  check("exitAll zeroes stake", (await vault.balanceOf(user.address)) === 0n);

  console.log("== emergency withdraw (forfeit) ==");
  await (await vault.connect(user).stake(ethers.parseEther("100"))).wait();
  await provider.send("evm_increaseTime", [86400]);
  await provider.send("evm_mine", []);
  const stakeTokBefore = await staking.balanceOf(user.address);
  await (await vault.connect(user).emergencyWithdraw()).wait();
  check("principal returned", (await staking.balanceOf(user.address)) === stakeTokBefore + ethers.parseEther("100"));
  check("rewards forfeited", (await vault.rewards(user.address)) === 0n);

  console.log("== owner rollover ==");
  await (await reward.mint(owner.address, ethers.parseEther("1000"))).wait();
  await (await reward.approve(VAULT, ethers.MaxUint256)).wait();
  const rateBefore = await vault.rewardRate();
  await (await vault.startRewards(ethers.parseEther("1000"), 86400n * 10n)).wait();
  // rollover recalculates the rate (leftover + new amount over the duration)
  check("rollover updates rate", (await vault.rewardRate()) !== rateBefore);

  console.log("== recoverERC20 guards ==");
  try {
    await vault.recoverERC20(await vault.stakingToken(), 1n);
    check("protected staking token reverts", false, "should have reverted");
  } catch (err) {
    const e = iface.parseError(err.data);
    check("ProtectedToken decoded", e && e.name === "ProtectedToken", e && e.name);
  }
  try {
    await vault.connect(user).recoverERC20(await vault.rewardsToken(), 1n);
    check("non-owner recover reverts", false, "should have reverted");
  } catch (err) {
    const e = iface.parseError(err.data);
    check("NotOwner decoded", e && e.name === "NotOwner", e && e.name);
  }

  console.log("== error decoding (same as the dApp) ==");
  try {
    await vault.connect(user).stake(0n);
    check("zero stake reverts", false, "should have reverted");
  } catch (err) {
    const e = iface.parseError(err.data);
    check("ZeroAmount decoded", e && e.name === "ZeroAmount", e && e.name);
  }
  try {
    await vault.connect(user).withdraw(ethers.parseEther("999999"));
    check("over-withdraw reverts", false, "should have reverted");
  } catch (err) {
    const e = iface.parseError(err.data);
    check("InsufficientStake decoded", e && e.name === "InsufficientStake", e && e.name);
  }

  console.log("== event feed (the dApp's getLogs flow) ==");
  const latest = await provider.getBlockNumber();
  const logs = await provider.getLogs({ address: VAULT, fromBlock: 0, toBlock: latest });
  const decoded = logs.map((l) => { try { return iface.parseLog(l); } catch { return null; } }).filter(Boolean);
  const names = decoded.map((d) => d.name);
  for (const n of ["Staked", "Withdrawn", "RewardPaid", "RewardsNotified", "EmergencyWithdrawn"]) {
    check(n + " present", names.includes(n));
  }

  console.log("\n" + (failed === 0 ? "SMOKE TEST PASSED" : "SMOKE TEST FAILED") + " — " + passed + " passed, " + failed + " failed");
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
