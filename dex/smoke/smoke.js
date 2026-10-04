/* ============================================================
   AMM DEX dApp — end-to-end smoke test (Node, no npm)
   Verifies the EXACT bundles the site uses (ethers v6 UMD + the
   shipped js/abi.js) against any deployed AMM (router + seeded pool).

     1. anvil                        (terminal 1)
     2. forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
     3. ROUTER=0x… node smoke/smoke.js
   ============================================================ */

const fs = require("fs");
const os = require("os");
const path = require("path");

const ETHER_VERSION = "6.13.4";
const ETHER_CDN = `https://cdn.jsdelivr.net/npm/ethers@${ETHER_VERSION}/dist/ethers.umd.min.js`;

const RPC = process.env.RPC || "http://127.0.0.1:8545";
const ROUTER = process.env.ROUTER;
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
  if (!ROUTER) {
    console.error("Usage: ROUTER=0x… node smoke/smoke.js");
    process.exit(2);
  }
  const ethers = await loadEthers();

  global.window = {};
  require(path.join(__dirname, "..", "js", "abi.js"));
  const ABI_R = window.AMM_ROUTER_ABI;
  const ABI_P = window.AMM_PAIR_ABI;
  const ABI_F = window.AMM_FACTORY_ABI;
  const ABI_T = window.IERC20_ABI;

  const provider = new ethers.JsonRpcProvider(RPC);
  const funder = new ethers.Wallet(FUNDER_KEY, provider);

  const router = new ethers.Contract(ROUTER, ABI_R, funder);
  const ifaceR = new ethers.Interface(ABI_R);
  const ifaceP = new ethers.Interface(ABI_P);

  // discover pair (first pool)
  const factory = new ethers.Contract(await router.factory(), ABI_F, funder);
  const pairAddr = await factory.allPairs(0);
  const pair = new ethers.Contract(pairAddr, ABI_P, funder);
  const tokA = new ethers.Contract(await pair.token0(), ABI_T, funder);
  const tokB = new ethers.Contract(await pair.token1(), ABI_T, funder);
  const symA = await tokA.symbol();
  const symB = await tokB.symbol();

  // fresh trader/LP per run
  const user = ethers.Wallet.createRandom().connect(provider);
  await (await funder.sendTransaction({ to: user.address, value: ethers.parseEther("0.5") })).wait();

  async function mintAndApprove(tok, amount) {
    await (await tok.mint(user.address, amount)).wait();
    await (await tok.connect(user).approve(ROUTER, amount)).wait();
  }

  function parsePair(rc, name) {
    return rc.logs.map((l) => { try { return ifaceP.parseLog(l); } catch { return null; } }).find((l) => l && l.name === name);
  }

  console.log("== reads ==");
  const [r0, r1] = await pair.getReserves();
  check("reserves seeded", r0 > 0n && r1 > 0n);
  const price = Number(ethers.formatEther(r1)) / Number(ethers.formatEther(r0));
  check("price ≈ 2 USD/GLD", Math.abs(price - 2) < 0.05, price.toFixed(4));
  check("LP supply > 0", (await pair.totalSupply()) > 0n);

  console.log("== swap " + symA + " → " + symB + " ==");
  await mintAndApprove(tokA, ethers.parseEther("1000"));
  const pathAB = [await tokA.getAddress(), await tokB.getAddress()];
  const outsAB = await router.getAmountsOut(ethers.parseEther("100"), pathAB);
  const expectedOut = outsAB[outsAB.length - 1];
  check("quote > 0", expectedOut > 0n);

  const balB0 = await tokB.balanceOf(user.address);
  const rc1 = await (await router.connect(user).swapExactTokensForTokens(
    ethers.parseEther("100"),
    (expectedOut * 995n) / 1000n,
    pathAB,
    user.address,
    BigInt(Math.floor(Date.now() / 1000) + 1200)
  )).wait();
  const swapEv = rc1.logs.map((l) => { try { return ifaceP.parseLog(l); } catch { return null; } }).find((l) => l && l.name === "Swap");
  check("Swap event", !!swapEv);
  check("received == quoted amount", (await tokB.balanceOf(user.address)) - balB0 === expectedOut, "got " + ((await tokB.balanceOf(user.address)) - balB0).toString() + " expected " + expectedOut.toString());

  console.log("== swap " + symB + " → " + symA + " (reverse direction) ==");
  await mintAndApprove(tokB, ethers.parseEther("2000"));
  const pathBA = [await tokB.getAddress(), await tokA.getAddress()];
  const outsBA = await router.getAmountsOut(ethers.parseEther("200"), pathBA);
  const expectedOutBA = outsBA[outsBA.length - 1];
  const balA0 = await tokA.balanceOf(user.address);
  await (await router.connect(user).swapExactTokensForTokens(
    ethers.parseEther("200"),
    (expectedOutBA * 995n) / 1000n,
    pathBA,
    user.address,
    BigInt(Math.floor(Date.now() / 1000) + 1200)
  )).wait();
  check("reverse swap received quoted amount", (await tokA.balanceOf(user.address)) - balA0 === expectedOutBA);

  console.log("== add liquidity ==");
  await mintAndApprove(tokA, ethers.parseEther("1000"));
  await mintAndApprove(tokB, ethers.parseEther("2000"));
  const lpBefore = await pair.balanceOf(user.address);
  const rc3 = await (await router.connect(user).addLiquidity(
    await tokA.getAddress(), await tokB.getAddress(),
    ethers.parseEther("1000"), ethers.parseEther("2000"),
    1n, 1n, user.address, BigInt(Math.floor(Date.now() / 1000) + 1200)
  )).wait();
  const mintEv = parsePair(rc3, "Mint");
  check("Mint event", !!mintEv);
  const lpGained = (await pair.balanceOf(user.address)) - lpBefore;
  check("LP tokens received", lpGained > 0n, lpGained.toString());
  const share = Number((lpGained * 10000n) / (await pair.totalSupply())) / 100;
  check("share in 0.05–1% range", share > 0.05 && share < 1, share.toFixed(3) + "%");

  console.log("== remove liquidity ==");
  // the router pulls LP tokens via transferFrom → approve the pair's LP token first
  await (await pair.connect(user).approve(ROUTER, lpGained)).wait();
  const balA1 = await tokA.balanceOf(user.address);
  const balB1 = await tokB.balanceOf(user.address);
  const rc4 = await (await router.connect(user).removeLiquidity(
    await tokA.getAddress(), await tokB.getAddress(),
    lpGained, 1n, 1n, user.address, BigInt(Math.floor(Date.now() / 1000) + 1200)
  )).wait();
  const burnEv = parsePair(rc4, "Burn");
  check("Burn event", !!burnEv);
  check("got back A", (await tokA.balanceOf(user.address)) - balA1 === burnEv.args.amount0);
  check("got back B", (await tokB.balanceOf(user.address)) - balB1 === burnEv.args.amount1);

  console.log("== error decoding (same as the dApp) ==");
  try {
    await router.getAmountsOut(0n, pathAB);
    check("zero-in quote reverts", false, "should have reverted");
  } catch (err) {
    const e = ifaceR.parseError(err.data);
    check("InsufficientAmount decoded", e && e.name === "InsufficientAmount", e && e.name);
  }
  try {
    await (await pair.connect(user).approve(ROUTER, ethers.parseEther("999999"))).wait();
    await router.connect(user).removeLiquidity(
      await tokA.getAddress(), await tokB.getAddress(),
      ethers.parseEther("999999"), 1n, 1n, user.address, BigInt(Math.floor(Date.now() / 1000) + 1200)
    );
    check("over-LP remove reverts", false, "should have reverted");
  } catch (err) {
    const e = ifaceP.parseError(err.data);
    // transferFrom's InsufficientBalance fires before burn's InsufficientLiquidityBurned
    check("over-LP remove reverts (balance guard)", e && (e.name === "InsufficientBalance" || e.name === "InsufficientLiquidityBurned"), e && e.name);
  }

  console.log("== event feed (the dApp's getLogs flow) ==");
  const latest = await provider.getBlockNumber();
  const logs = await provider.getLogs({ address: pairAddr, fromBlock: 0, toBlock: latest });
  const decoded = logs.map((l) => { try { return ifaceP.parseLog(l); } catch { return null; } }).filter(Boolean);
  const names = decoded.map((d) => d.name);
  for (const n of ["Swap", "Mint", "Burn", "Sync"]) {
    check(n + " present", names.includes(n));
  }

  console.log("\n" + (failed === 0 ? "SMOKE TEST PASSED" : "SMOKE TEST FAILED") + " — " + passed + " passed, " + failed + " failed");
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
