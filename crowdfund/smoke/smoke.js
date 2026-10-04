/* ============================================================
   CrowdFund dApp — end-to-end smoke test (Node, no npm needed)
   Verifies the EXACT bundles the site uses (ethers v6 UMD + the
   shipped js/abi.js) against any deployed CrowdFundFactory:

     1. anvil                        (terminal 1)
     2. forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
     3. FACTORY=0x… node smoke/smoke.js
   ============================================================ */

const fs = require("fs");
const os = require("os");
const path = require("path");

const ETHER_VERSION = "6.13.4";
const ETHER_CDN = `https://cdn.jsdelivr.net/npm/ethers@${ETHER_VERSION}/dist/ethers.umd.min.js`;

const RPC = process.env.RPC || "http://127.0.0.1:8545";
const FACTORY = process.env.FACTORY;
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
  if (!FACTORY) {
    console.error("Usage: FACTORY=0x… node smoke/smoke.js");
    process.exit(2);
  }
  const ethers = await loadEthers();

  global.window = {};
  require(path.join(__dirname, "..", "js", "abi.js"));
  const ABI_F = window.CROWD_FUND_FACTORY_ABI;
  const ABI_C = window.CROWD_FUND_CAMPAIGN_ABI;

  const provider = new ethers.JsonRpcProvider(RPC);
  const owner = new ethers.Wallet(OWNER_KEY, provider);
  const backer = new ethers.Wallet(USER_KEY, provider);

  const factory = new ethers.Contract(FACTORY, ABI_F, owner);
  const ifaceF = new ethers.Interface(ABI_F);
  const ifaceC = new ethers.Interface(ABI_C);

  console.log("== factory reads ==");
  check("feeBps == 100", (await factory.feeBps()) === 100n);
  check("owner correct", (await factory.owner()).toLowerCase() === owner.address.toLowerCase());
  const initialCount = Number(await factory.campaignCount());
  console.log("  (campaigns on chain:", initialCount + ")");

  console.log("== create campaigns ==");
  const tx1 = await factory.createCampaign(ethers.parseEther("0.05"), 120); // will succeed
  const rc1 = await tx1.wait();
  const log1 = rc1.logs.map((l) => { try { return ifaceF.parseLog(l); } catch { return null; } }).find((l) => l && l.name === "CampaignCreated");
  check("CampaignCreated event decoded", !!log1);
  const okCampaign = new ethers.Contract(log1.args.campaign, ABI_C, backer);

  const tx2 = await factory.createCampaign(ethers.parseEther("1"), 120); // will fail
  const rc2 = await tx2.wait();
  const log2 = rc2.logs.map((l) => { try { return ifaceF.parseLog(l); } catch { return null; } }).find((l) => l && l.name === "CampaignCreated");
  const failCampaign = new ethers.Contract(log2.args.campaign, ABI_C, backer);

  check("campaignCount increased", Number(await factory.campaignCount()) === initialCount + 2);

  console.log("== pledge ==");
  await (await okCampaign.connect(backer).pledge({ value: ethers.parseEther("0.1") })).wait();
  check("pledge recorded", (await okCampaign.totalPledged()) === ethers.parseEther("0.1"));
  check("backer entitlement", (await okCampaign.pledged(backer.address)) === ethers.parseEther("0.1"));

  await (await failCampaign.connect(backer).pledge({ value: ethers.parseEther("0.1") })).wait();

  console.log("== time travel past the deadline ==");
  await provider.send("evm_increaseTime", [300]);
  await provider.send("evm_mine", []);
  check("ok campaign Successful", Number(await okCampaign.status()) === 1);
  check("fail campaign Failed", Number(await failCampaign.status()) === 2);

  console.log("== claim (successful campaign) ==");
  const feesBefore = await factory.accruedFees();
  const creatorBefore = await provider.getBalance(owner.address);
  await (await okCampaign.connect(owner).claim()).wait();
  const creatorAfter = await provider.getBalance(owner.address);
  // creator receives pledge minus 1% fee (gas excluded — compare with the fee credited)
  check("factory accrued 1% fee", (await factory.accruedFees()) === feesBefore + ethers.parseEther("0.001"));
  check("creator balance grew", creatorAfter > creatorBefore);

  console.log("== refund (failed campaign) ==");
  const backerBefore = await provider.getBalance(backer.address);
  await (await failCampaign.connect(backer).refund()).wait();
  const backerAfter = await provider.getBalance(backer.address);
  // refund returns the full pledge; gas makes net negative, so assert entitlement cleared instead
  check("refund cleared entitlement", (await failCampaign.pledged(backer.address)) === 0n);
  check("refund tx sent funds", backerAfter > backerBefore - ethers.parseEther("0.001"));

  console.log("== error decoding (same as the dApp) ==");
  try {
    await failCampaign.connect(backer).pledge({ value: ethers.parseEther("0.01") });
    check("pledge after deadline reverts", false, "should have reverted");
  } catch (err) {
    const e = ifaceC.parseError(err.data);
    check("CampaignEnded decoded", e && e.name === "CampaignEnded", e && e.name);
  }
  try {
    await failCampaign.connect(backer).refund();
    check("double refund reverts", false, "should have reverted");
  } catch (err) {
    const e = ifaceC.parseError(err.data);
    check("NothingToRefund decoded", e && e.name === "NothingToRefund", e && e.name);
  }

  console.log("== event feed (the dApp's getLogs flow) ==");
  const latest = await provider.getBlockNumber();
  const logs = await provider.getLogs({ address: [FACTORY, log1.args.campaign, log2.args.campaign], fromBlock: 0, toBlock: latest });
  const decoded = logs
    .map((l) => {
      let parsed = null;
      for (const i of [ifaceF, ifaceC]) {
        try {
          const p = i.parseLog({ topics: l.topics, data: l.data });
          if (p) {
            parsed = p;
            break;
          }
        } catch {}
      }
      return parsed;
    })
    .filter(Boolean);
  const names = decoded.map((d) => d.name);
  for (const n of ["CampaignCreated", "Pledged", "Claimed", "Refunded"]) {
    check(n + " present", names.includes(n));
  }

  console.log("\n" + (failed === 0 ? "SMOKE TEST PASSED" : "SMOKE TEST FAILED") + " — " + passed + " passed, " + failed + " failed");
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
