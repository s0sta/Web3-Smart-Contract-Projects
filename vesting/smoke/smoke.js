/* ============================================================
   TokenVesting dApp — end-to-end smoke test (Node, no npm)
   Verifies the EXACT bundles the site uses (ethers v6 UMD + the
   shipped js/abi.js) against any deployed TokenVesting.

   No time travel: every schedule uses a start offset relative to
   the current chain tip, so each phase is deterministic and the
   test is fully re-runnable.

     1. anvil                        (terminal 1)
     2. forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
     3. VESTING=0x… node smoke/smoke.js
   ============================================================ */

const fs = require("fs");
const os = require("os");
const path = require("path");

const ETHER_VERSION = "6.13.4";
const ETHER_CDN = `https://cdn.jsdelivr.net/npm/ethers@${ETHER_VERSION}/dist/ethers.umd.min.js`;

const RPC = process.env.RPC || "http://127.0.0.1:8545";
const VESTING = process.env.VESTING;
const OWNER_KEY = process.env.OWNER_KEY || "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"; // anvil #0

const DAY = 86400n;

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
  if (!VESTING) {
    console.error("Usage: VESTING=0x… node smoke/smoke.js");
    process.exit(2);
  }
  const ethers = await loadEthers();

  global.window = {};
  require(path.join(__dirname, "..", "js", "abi.js"));
  const ABI_V = window.TOKEN_VESTING_ABI;
  const ABI_T = window.IERC20_ABI;

  const provider = new ethers.JsonRpcProvider(RPC);
  // NonceManager tracks the account nonce across the many sequential txs in this test
  const owner = new ethers.NonceManager(new ethers.Wallet(OWNER_KEY, provider));
  const ownerAddr = new ethers.Wallet(OWNER_KEY).address; // NonceManager has no .address

  const vesting = new ethers.Contract(VESTING, ABI_V, owner);
  const iface = new ethers.Interface(ABI_V);
  const token = new ethers.Contract(await vesting.token(), ABI_T, owner);

  const tip = async () => Number((await provider.getBlock("latest")).timestamp);

  async function freshWallet() {
    const w = ethers.Wallet.createRandom().connect(provider);
    await (await owner.sendTransaction({ to: w.address, value: ethers.parseEther("0.1") })).wait();
    return w;
  }

  async function fundOwner(amount) {
    await (await token.mint(ownerAddr, amount)).wait();
    if ((await token.allowance(ownerAddr, VESTING)) < amount) {
      await (await token.approve(VESTING, ethers.MaxUint256)).wait();
    }
  }

  function parse(rc, name) {
    return rc.logs.map((l) => { try { return iface.parseLog(l); } catch { return null; } }).find((l) => l && l.name === name);
  }

  console.log("== reads ==");
  check("owner correct", (await vesting.owner()).toLowerCase() === ownerAddr.toLowerCase());
  check("token address set", ethers.isAddress(await vesting.token()));

  console.log("== future start: cliff pending, nothing to claim ==");
  const ben1 = await freshWallet();
  await fundOwner(ethers.parseEther("1000"));
  const t1 = await tip();
  await (await vesting.createSchedule(ben1.address, ethers.parseEther("1000"), t1 + 86400 * 10, 30n * DAY, 90n * DAY)).wait();
  const s1 = await vesting.schedules(ben1.address);
  check("total 1000", s1.totalAmount === ethers.parseEther("1000"));
  check("cliff = start + 30d", Number(s1.cliff) === Number(s1.start) + 86400 * 30);
  check("end = cliff + 90d", Number(s1.end) === Number(s1.cliff) + 86400 * 90);
  check("vested 0 (future start)", (await vesting.vestedAmount(ben1.address)) === 0n);
  try {
    await vesting.connect(ben1).claim();
    check("claim reverts pre-cliff", false, "should have reverted");
  } catch (err) {
    const e = iface.parseError(err.data);
    check("NothingToClaim decoded", e && e.name === "NothingToClaim", e && e.name);
  }

  console.log("== start in past: linear vesting, exact claim ==");
  const ben2 = await freshWallet();
  await fundOwner(ethers.parseEther("1000"));
  const t2 = await tip();
  // start = tip − 90d → cliff = tip − 60d, end = tip + 30d → 2/3 vested
  await (await vesting.createSchedule(ben2.address, ethers.parseEther("1000"), t2 - 86400 * 90, 30n * DAY, 90n * DAY)).wait();
  const s2 = await vesting.schedules(ben2.address);
  const tip2 = await tip();
  const expected2 = (ethers.parseEther("1000") * BigInt(tip2 - Number(s2.cliff))) / BigInt(Number(s2.end) - Number(s2.cliff));
  const vested2 = await vesting.vestedAmount(ben2.address);
  check("vested = total × elapsed/(end−cliff)", vested2 === expected2, vested2.toString() + " vs " + expected2.toString());

  const tokBefore = await token.balanceOf(ben2.address);
  const rc2 = await (await vesting.connect(ben2).claim()).wait();
  const claimedEv = parse(rc2, "Claimed");
  check("Claimed event", !!claimedEv);
  check("beneficiary received exact amount", (await token.balanceOf(ben2.address)) === tokBefore + claimedEv.args.amount);
  check("releasable ≤ 1 wei after claim", (await vesting.releasable(ben2.address)) <= 1n); // block may tick 1s

  console.log("== end in past: fully vested ==");
  const ben3 = await freshWallet();
  await fundOwner(ethers.parseEther("1000"));
  const t3 = await tip();
  await (await vesting.createSchedule(ben3.address, ethers.parseEther("1000"), t3 - 86400 * 120, 10n * DAY, 30n * DAY)).wait();
  check("fully vested (end passed)", (await vesting.vestedAmount(ben3.address)) === ethers.parseEther("1000"));
  check("releasable == total", (await vesting.releasable(ben3.address)) === ethers.parseEther("1000"));

  console.log("== revoke: unvested returns, accrual frozen at revokedAt ==");
  const ben4 = await freshWallet();
  await fundOwner(ethers.parseEther("500"));
  const t4 = await tip();
  // start = tip − 45d → cliff = tip − 30d, end = tip + 30d → halfway
  await (await vesting.createSchedule(ben4.address, ethers.parseEther("500"), t4 - 86400 * 45, 15n * DAY, 60n * DAY)).wait();
  const s4 = await vesting.schedules(ben4.address);
  const ownerTokBefore = await token.balanceOf(ownerAddr);
  const rv = await (await vesting.revokeSchedule(ben4.address)).wait();
  const revokedEv = parse(rv, "ScheduleRevoked");
  check("ScheduleRevoked event", !!revokedEv);
  const revokeBlock = await provider.getBlock(rv.blockNumber);
  const vestedAtRevoke = (ethers.parseEther("500") * BigInt(Number(revokeBlock.timestamp) - Number(s4.cliff))) / BigInt(Number(s4.end) - Number(s4.cliff));
  check("unvested returned to owner", (await token.balanceOf(ownerAddr)) === ownerTokBefore + ethers.parseEther("500") - vestedAtRevoke);
  check("schedule flagged revoked", (await vesting.schedules(ben4.address)).revoked === true);
  check("accrual frozen at revokedAt", (await vesting.vestedAmount(ben4.address)) === vestedAtRevoke);

  console.log("== error decoding (same as the dApp) ==");
  try {
    await vesting.connect(owner).claim();
    check("no-schedule claim reverts", false, "should have reverted");
  } catch (err) {
    const e = iface.parseError(err.data);
    check("NoSchedule decoded", e && e.name === "NoSchedule", e && e.name);
  }
  try {
    const t5 = await tip();
    await vesting.createSchedule(ben1.address, 1n, t5, 10n, 10n);
    check("duplicate schedule reverts", false, "should have reverted");
  } catch (err) {
    const e = iface.parseError(err.data);
    check("ScheduleExists decoded", e && e.name === "ScheduleExists", e && e.name);
  }

  console.log("== event feed (the dApp's getLogs flow) ==");
  const latest = await provider.getBlockNumber();
  const logs = await provider.getLogs({ address: VESTING, fromBlock: 0, toBlock: latest });
  const decoded = logs.map((l) => { try { return iface.parseLog(l); } catch { return null; } }).filter(Boolean);
  const names = decoded.map((d) => d.name);
  for (const n of ["ScheduleCreated", "Claimed", "ScheduleRevoked"]) {
    check(n + " present", names.includes(n));
  }

  console.log("\n" + (failed === 0 ? "SMOKE TEST PASSED" : "SMOKE TEST FAILED") + " — " + passed + " passed, " + failed + " failed");
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
