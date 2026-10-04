/* ============================================================
   NovaToken dApp — end-to-end smoke test (Node, no npm needed)
   ------------------------------------------------------------
   Verifies the EXACT bundles the site uses (ethers v6 UMD + the
   shipped js/abi.js) against any deployed NovaToken:

     1. anvil                        (terminal 1)
     2. forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
     3. TOKEN=0x... node smoke/smoke.js
   ============================================================ */

const fs = require("fs");
const os = require("os");
const path = require("path");

const ETHER_VERSION = "6.13.4";
const ETHER_CDN = `https://cdn.jsdelivr.net/npm/ethers@${ETHER_VERSION}/dist/ethers.umd.min.js`;

const RPC = process.env.RPC || "http://127.0.0.1:8545";
const TOKEN = process.env.TOKEN;
const OWNER_KEY = process.env.OWNER_KEY || "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"; // anvil #0
const USER_KEY = process.env.USER_KEY || "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"; // anvil #1
const THIRD_KEY = process.env.THIRD_KEY || "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"; // anvil #2

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
  if (!TOKEN) {
    console.error("Usage: TOKEN=0x… node smoke/smoke.js");
    process.exit(2);
  }
  const ethers = await loadEthers();

  // Load the shipped ABI exactly like index.html does.
  global.window = {};
  require(path.join(__dirname, "..", "js", "abi.js"));
  const ABI = window.NOVA_TOKEN_ABI;

  const provider = new ethers.JsonRpcProvider(RPC);
  const owner = new ethers.Wallet(OWNER_KEY, provider);
  const user = new ethers.Wallet(USER_KEY, provider);
  const third = new ethers.Wallet(THIRD_KEY, provider);

  const token = new ethers.Contract(TOKEN, ABI, owner);
  const iface = new ethers.Interface(ABI);

  console.log("== reads ==");
  check("name()", (await token.name()) === "NovaToken", await token.name());
  check("symbol()", (await token.symbol()) === "NOVA");
  check("decimals()", (await token.decimals()) === 18n);
  check("MAX_SUPPLY()", (await token.MAX_SUPPLY()) === 100_000_000n * 10n ** 18n);
  check("owner()", (await token.owner()).toLowerCase() === owner.address.toLowerCase());

  console.log("== mint / transfer ==");
  const userBalBefore = await token.balanceOf(user.address);
  await (await token.mint(user.address, ethers.parseUnits("1000", 18))).wait();
  check("mint adds 1000", (await token.balanceOf(user.address)) === userBalBefore + ethers.parseUnits("1000", 18));

  const thirdBalBefore = await token.balanceOf(third.address);
  await (await token.connect(user).transfer(third.address, ethers.parseUnits("100", 18))).wait();
  check("transfer adds 100 to recipient", (await token.balanceOf(third.address)) === thirdBalBefore + ethers.parseUnits("100", 18));
  check("transfer subtracts 100 from sender", (await token.balanceOf(user.address)) === userBalBefore + ethers.parseUnits("900", 18));

  console.log("== approve / transferFrom ==");
  await (await token.connect(user).approve(third.address, ethers.parseUnits("500", 18))).wait();
  await (await token.connect(third).transferFrom(user.address, owner.address, ethers.parseUnits("100", 18))).wait();
  check("allowance 500→400", (await token.allowance(user.address, third.address)) === ethers.parseUnits("400", 18));

  console.log("== EIP-2612 permit (the dApp's signTypedData flow) ==");
  const network = await provider.getNetwork();
  const domain = { name: await token.name(), version: "1", chainId: Number(network.chainId), verifyingContract: TOKEN };
  const types = { Permit: [
    { name: "owner", type: "address" },
    { name: "spender", type: "address" },
    { name: "value", type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ]};
  const nonce = await token.nonces(user.address);
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
  const message = { owner: user.address, spender: third.address, value: ethers.parseUnits("777", 18), nonce, deadline };
  const signature = await user.signTypedData(domain, types, message);
  const sig = ethers.Signature.from(signature);

  await (await token.connect(third).permit(user.address, third.address, message.value, deadline, sig.v, sig.r, sig.s)).wait();
  check("permit set allowance 777", (await token.allowance(user.address, third.address)) === message.value);
  check("nonce incremented", (await token.nonces(user.address)) === nonce + 1n);

  console.log("== burn / pause / error decoding ==");
  const supplyBefore = await token.totalSupply();
  await (await token.connect(user).burn(ethers.parseUnits("50", 18))).wait();
  check("burn reduced supply", (await token.totalSupply()) === supplyBefore - ethers.parseUnits("50", 18));

  await (await token.pause()).wait();
  check("paused flag", (await token.paused()) === true);
  try {
    await token.connect(user).transfer(third.address, 1n);
    check("transfer while paused reverted", false, "should have reverted");
  } catch (err) {
    const e = iface.parseError(err.data); // same decode as the dApp
    check("custom error decoded", e && e.name === "TokenPaused", e && e.name);
  }
  await (await token.unpause()).wait();

  console.log("== event feed (the dApp's getLogs flow) ==");
  const latest = await provider.getBlockNumber();
  const logs = await provider.getLogs({ address: TOKEN, fromBlock: 0, toBlock: latest });
  const decoded = logs.map((l) => { try { return iface.parseLog({ topics: l.topics, data: l.data }); } catch { return null; } }).filter(Boolean);
  const names = decoded.map((d) => d.name);
  check("Transfer events present", names.includes("Transfer"));
  check("Minted event present", names.includes("Minted"));
  check("Burned event present", names.includes("Burned"));
  check("Approval event present", names.includes("Approval"));
  check("Paused event present", names.includes("Paused"));

  console.log("\n" + (failed === 0 ? "SMOKE TEST PASSED" : "SMOKE TEST FAILED") + " — " + passed + " passed, " + failed + " failed");
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
