/* ============================================================
   AMM DEX dApp — application logic
   ethers.js v6 (UMD global), no build step.
   ============================================================ */

"use strict";

(function () {
  const $ = (s) => document.querySelector(s);
  const cfg = window.APP_CONFIG || {};
  const ABI_R = window.AMM_ROUTER_ABI || [];
  const ABI_P = window.AMM_PAIR_ABI || [];
  const ABI_F = window.AMM_FACTORY_ABI || [];
  const ABI_T = window.IERC20_ABI || [];

  const LS_ADDRESS = "amm.routerAddress";
  const LS_CHAIN = "amm.chainId";

  const DEADLINE = () => BigInt(Math.floor(Date.now() / 1000) + 1200);

  /* ---------------- state ---------------- */
  let ifaceR = null;
  let ifaceP = null;
  let routerAddress = localStorage.getItem(LS_ADDRESS) || cfg.routerAddress || "";
  let chainIdPref = Number(localStorage.getItem(LS_CHAIN) || cfg.defaultChainId);
  let readProvider = null;
  let walletProvider = null;
  let signer = null;
  let account = null;
  let routerRO = null;
  let routerRW = null;
  let pairRO = null;
  let pairAddress = null;
  let chainId = null;
  let tokA = null; // contract handles (RO)
  let tokB = null;
  let addrA = null;
  let addrB = null;
  let symA = "GLD";
  let symB = "USD";
  let reserves = { a: 0n, b: 0n };
  let lpSupply = 0n;
  let direction = true; // true = pay A (GLD), receive B (USD)
  let amountIn = 0n;

  /* ---------------- helpers ---------------- */

  function chainCfg(id) {
    return cfg.chains[id] || { name: "Unknown network", short: "unknown", rpc: null, explorer: null, currency: "ETH" };
  }

  function rpcFor(id) {
    return chainCfg(id).rpc || "https://ethereum-rpc.publicnode.com";
  }

  /* RPC resilience: keep a list of endpoints to fall back on if a read fails */
  let rpcFailures = 0;
  function fallbackRpc(id) {
    const fallbacks = chainCfg(id).rpcFallbacks || [];
    return fallbacks[rpcFailures % (fallbacks.length || 1)];
  }

  function rebuildReadProvider() {
    const rpc = rpcFailures > 0 ? fallbackRpc(chainId ?? chainIdPref) : rpcFor(chainId ?? chainIdPref);
    readProvider = new ethers.JsonRpcProvider(rpc);
    routerRO = new ethers.Contract(routerAddress, ABI_R, readProvider);
    pairRO = null; // force re-discovery on the new endpoint
  }

  function shortAddr(a) {
    if (!a) return "—";
    a = String(a);
    return a.length > 12 ? a.slice(0, 6) + "…" + a.slice(-4) : a;
  }

  function fmtUnits(bn, dec = 18) {
    try {
      const f = ethers.formatUnits(bn, dec);
      const n = Number(f);
      const compact =
        n >= 1e6 ? new Intl.NumberFormat("en", { notation: "compact", maximumFractionDigits: 2 }).format(n) :
        n >= 1 ? new Intl.NumberFormat("en", { maximumFractionDigits: 4 }).format(n) :
        new Intl.NumberFormat("en", { maximumFractionDigits: 6 }).format(n);
      return { short: compact, full: f };
    } catch {
      return { short: "—", full: "—" };
    }
  }

  function explorerLink(path) {
    const ex = chainCfg(chainId ?? chainIdPref).explorer;
    return ex ? ex + path : null;
  }

  function txLink(hash) {
    const base = explorerLink("/tx/" + hash);
    return base ? '<a href="' + base + '" target="_blank" rel="noopener">' + shortAddr(hash) + " ↗</a>" : shortAddr(hash);
  }

  function addrLink(addr) {
    const base = explorerLink("/address/" + addr);
    return base ? '<a href="' + base + '" target="_blank" rel="noopener">' + shortAddr(addr) + "</a>" : shortAddr(addr);
  }

  /* ---------------- toasts & errors ---------------- */

  function toast(message, type = "info", ttl = 6000) {
    const box = $("#toast-container");
    const el = document.createElement("div");
    el.className = "toast " + type;
    el.innerHTML = message;
    box.appendChild(el);
    setTimeout(() => {
      el.classList.add("out");
      setTimeout(() => el.remove(), 300);
    }, ttl);
  }

  function decodeError(err) {
    if (!err) return "Unknown error";
    if (err.revert && err.revert.name) {
      const args = (err.revert.args || []).map((a) => (typeof a === "bigint" ? fmtUnits(a).short : shortAddr(String(a)))).join(", ");
      return err.revert.name + (args ? "(" + args + ")" : "");
    }
    for (const iface of [ifaceR, ifaceP]) {
      if (err.data && iface) {
        try {
          const e = iface.parseError(err.data);
          if (e) {
            const args = e.args.map((a) => (typeof a === "bigint" ? fmtUnits(a).short : shortAddr(String(a)))).join(", ");
            return e.name + (args ? "(" + args + ")" : "");
          }
        } catch {}
      }
    }
    if (err.shortMessage) {
      const m = err.shortMessage;
      if (m.includes("user rejected")) return "Transaction rejected in wallet";
      if (m.includes("insufficient funds")) return "Insufficient ETH for gas";
      return m;
    }
    return err.message || String(err);
  }

  /* ---------------- setup ---------------- */

  async function init() {
    if (typeof ethers === "undefined") {
      toast("ethers.js failed to load — check your internet connection", "error", 12000);
      return;
    }
    ifaceR = new ethers.Interface(ABI_R);
    ifaceP = new ethers.Interface(ABI_P);

    try {
      const res = await fetch("api/config.php", { cache: "no-store" });
      if (res.ok) {
        const data = await res.json();
        if (data && data.routerAddress && !localStorage.getItem(LS_ADDRESS)) {
          routerAddress = data.routerAddress;
        }
        if (data && data.github) cfg.github = data.github;
        if (data && data.tokenA) cfg.tokenA = data.tokenA;
        if (data && data.tokenB) cfg.tokenB = data.tokenB;
      }
    } catch {}

    populateChainSelect();
    applyAddressAndChain();

    if (window.ethereum) {
      walletProvider = new ethers.BrowserProvider(window.ethereum);
      window.ethereum.on("accountsChanged", onAccountsChanged);
      window.ethereum.on("chainChanged", () => window.location.reload());
      try {
        const accts = await walletProvider.send("eth_accounts", []);
        if (accts.length > 0) {
          account = accts[0];
          signer = await walletProvider.getSigner();
        }
      } catch {}
    }

    bindUi();
    await refreshAll();
  }

  function applyAddressAndChain() {
    // ignore stale local network choices (e.g. a saved "Local (Anvil)" or unknown id)
    let savedChain = Number(localStorage.getItem(LS_CHAIN) || cfg.defaultChainId);
    if (!cfg.chains[savedChain] || savedChain === 31337) {
      savedChain = cfg.defaultChainId;
      localStorage.removeItem(LS_CHAIN);
    }
    chainIdPref = savedChain;
    routerAddress = localStorage.getItem(LS_ADDRESS) || routerAddress || "";

    readProvider = new ethers.JsonRpcProvider(rpcFor(chainIdPref));
    chainId = chainIdPref;

    if (routerAddress && ethers.isAddress(routerAddress)) {
      routerRO = new ethers.Contract(routerAddress, ABI_R, readProvider);
    } else {
      routerRO = null;
    }
    routerRW = null;
    pairRO = null;
    pairAddress = null;

    $("#setup-banner").hidden = !!routerRO;
    $("#chain-badge").textContent = chainCfg(chainIdPref).name;
    $("#chain-badge").classList.toggle("ok", !!chainCfg(chainIdPref).rpc);
    $("#footer-address").textContent = routerRO ? shortAddr(routerAddress) : "not configured";
    const ex = chainCfg(chainIdPref).explorer;
    $("#footer-github").href = cfg.github || "#";
    $("#footer-explorer").href = ex || "#";
  }

  function populateChainSelect() {
    const sel = $("#set-chain");
    sel.innerHTML = "";
    Object.entries(cfg.chains).forEach(([id, c]) => {
      const opt = document.createElement("option");
      opt.value = id;
      opt.textContent = c.name;
      if (Number(id) === chainIdPref) opt.selected = true;
      sel.appendChild(opt);
    });
  }

  /* ---------------- pool discovery ---------------- */

  function normAddr(a) {
    try { return ethers.getAddress(a); } catch { return String(a).toLowerCase(); }
  }

  async function discoverPool() {
    const factory = new ethers.Contract(await routerRO.factory(), ABI_F, readProvider);
    if (cfg.tokenA && cfg.tokenB) {
      addrA = normAddr(cfg.tokenA);
      addrB = normAddr(cfg.tokenB);
      pairAddress = await factory.getPair(addrA, addrB);
      if (pairAddress && pairAddress !== ethers.ZeroAddress) {
        await attachPair();
        return;
      }
    }
    // fallback: the first pool created on this factory
    const n = Number(await factory.allPairsLength());
    if (n > 0) {
      pairAddress = await factory.allPairs(n - 1);
      await attachPair();
    }
  }

  async function attachPair() {
    pairRO = new ethers.Contract(pairAddress, ABI_P, readProvider);
    addrA = await pairRO.token0();
    addrB = await pairRO.token1();
    tokA = new ethers.Contract(addrA, ABI_T, readProvider);
    tokB = new ethers.Contract(addrB, ABI_T, readProvider);
    try { symA = await tokA.symbol(); } catch {}
    try { symB = await tokB.symbol(); } catch {}
    $("#pair-addr").textContent = "pair: " + shortAddr(pairAddress) + " · " + symA + "/" + symB;
    $("#pool-chip").textContent = symA + "/" + symB + " · 0.3%";
  }

  /* ---------------- wallet ---------------- */

  async function connect() {
    if (!window.ethereum) {
      toast("No wallet detected — install MetaMask and refresh", "error", 9000);
      return;
    }
    const btn = $("#btn-connect");
    btn.disabled = true;
    try {
      walletProvider = new ethers.BrowserProvider(window.ethereum);
      const accts = await walletProvider.send("eth_requestAccounts", []);
      account = accts[0];
      signer = await walletProvider.getSigner();
      const net = await walletProvider.getNetwork();
      chainId = Number(net.chainId);

      if (chainId !== chainIdPref) {
        const ok = await trySwitchChain(chainIdPref);
        if (ok) chainId = chainIdPref;
        else toast("You are on " + chainCfg(chainId).name + " — switch to " + chainCfg(chainIdPref).name + " in Settings or in your wallet", "info", 9000);
      }

      await refreshAll();
      toast("Connected: " + shortAddr(account), "success");
    } catch (err) {
      toast(decodeError(err), "error");
    } finally {
      btn.disabled = false;
    }
  }

  async function onAccountsChanged(accts) {
    if (accts.length === 0) {
      account = null;
      signer = null;
      routerRW = null;
      await refreshAll();
      toast("Wallet disconnected", "info");
    } else {
      account = accts[0];
      signer = await walletProvider.getSigner();
      await refreshAll();
    }
  }

  async function trySwitchChain(target) {
    if (!walletProvider) return false;
    const hex = "0x" + target.toString(16);
    try {
      await walletProvider.send("wallet_switchEthereumChain", [{ chainId: hex }]);
      return true;
    } catch (err) {
      if (err && (err.code === 4902 || (err.data && err.data.code === 4902))) {
        try {
          const c = chainCfg(target);
          await walletProvider.send("wallet_addEthereumChain", [{
            chainId: hex,
            chainName: c.name,
            rpcUrls: [c.rpc],
            nativeCurrency: { name: c.currency, symbol: c.currency, decimals: 18 },
            blockExplorerUrls: c.explorer ? [c.explorer] : [],
          }]);
          return true;
        } catch {
          return false;
        }
      }
      return false;
    }
  }

  /* ---------------- rendering ---------------- */

  async function refreshAll() {
    renderWalletButton();
    await refreshPool();
    await refreshSwapPreview();
    await refreshLiquidity();
    await refreshPosition();
    await refreshEvents();
  }

  function renderWalletButton() {
    const btn = $("#btn-connect");
    btn.textContent = account ? shortAddr(account) : "Connect Wallet";
    btn.title = account || "";
  }

  async function refreshPool(silent) {
    if (!routerRO) return;
    try {
      if (!pairRO) await discoverPool();
      if (!pairRO) return;
      const [r0, r1] = await pairRO.getReserves();
      reserves.a = r0;
      reserves.b = r1;
      lpSupply = await pairRO.totalSupply();

      const aF = fmtUnits(r0);
      const bF = fmtUnits(r1);
      setKpi("kpi-gld", aF.short + " " + symA, aF.full);
      setKpi("kpi-usd", bF.short + " " + symB, bF.full);
      const price = r0 > 0n && r1 > 0n ? Number(ethers.formatEther(r1)) / Number(ethers.formatEther(r0)) : 0;
      setKpi("kpi-price", price > 0 ? price.toFixed(3) + " " + symB + " / " + symA : "—", "");
      setKpi("kpi-lp", fmtUnits(lpSupply).short, fmtUnits(lpSupply).full);

      // composition gauge: value of A (in B terms) vs B
      const worthA = r0 > 0n && r1 > 0n ? (r0 * r1 * 10000n) / r0 : 0n; // A valued in B = r0 × price = r1… split 50/50 by design; show reserve split instead
      const totalR = r0 + r1;
      const gldPct = totalR > 0n ? Number((r0 * 10000n) / totalR) / 100 : 0;
      $("#gauge-gld").style.width = gldPct.toFixed(1) + "%";
      $("#gauge-gld-label").textContent = symA + " " + (gldPct).toFixed(1) + "%";
      $("#gauge-usd-label").textContent = symB + " " + (100 - gldPct).toFixed(1) + "%";
    } catch (err) {
      console.warn("pool:", err);
      const fallbacks = chainCfg(chainId ?? chainIdPref).rpcFallbacks || [];
      if (rpcFailures < fallbacks.length) {
        // try the next RPC endpoint before giving up
        rpcFailures++;
        rebuildReadProvider();
        toast("Retrying with a backup RPC endpoint…", "info", 4000);
        await refreshPool(silent);
        return;
      }
      rpcFailures = 0;
      rebuildReadProvider();
      if (!silent) {
        toast(
          "Could not read the pool — " + (err.shortMessage || err.message || "") +
          '<br/><span style="opacity:.7">If this persists, open ⚙ Settings, pick a network, and clear any saved address.</span>',
          "error", 12000
        );
      }
    }
  }

  function setKpi(id, text, title) {
    const el = $("#" + id);
    if (el.textContent !== text) {
      el.textContent = text;
      el.classList.remove("bump");
      void el.offsetWidth; // restart animation
      el.classList.add("bump");
    }
    if (title) el.title = title;
  }

  /* count-up on first load for the price KPI */
  function countUp(el, targetText) {
    // only meaningful for pure numbers; used sparingly
    return targetText;
  }

  /* ---------------- swap ---------------- */

  function inTok() { return direction ? tokA : tokB; }
  function outTok() { return direction ? tokB : tokA; }
  function inAddr() { return direction ? addrA : addrB; }
  function outAddr() { return direction ? addrB : addrA; }
  function inSym() { return direction ? symA : symB; }
  function outSym() { return direction ? symB : symA; }
  function reserveIn() { return direction ? reserves.a : reserves.b; }
  function reserveOut() { return direction ? reserves.b : reserves.a; }

  async function refreshSwapPreview() {
    $("#token-in").textContent = inSym();
    $("#token-out").textContent = outSym();
    if (account) {
      try {
        const bal = await inTok().balanceOf(account);
        $("#bal-in").textContent = fmtUnits(bal).short + " " + inSym();
      } catch { $("#bal-in").textContent = "—"; }
    } else {
      $("#bal-in").textContent = "—";
    }
    await computeOut();
  }

  async function computeOut() {
    const amtStr = $("#swap-in").value;
    if (!amtStr || Number(amtStr) <= 0) {
      amountIn = 0n;
      $("#swap-out").value = "";
      $("#meta-rate").textContent = "—";
      $("#meta-impact").textContent = "—";
      $("#meta-min").textContent = "—";
      return;
    }
    try {
      amountIn = ethers.parseEther(amtStr);
      const path = [inAddr(), outAddr()];
      const outs = await routerRO.getAmountsOut(amountIn, path);
      const out = outs[outs.length - 1];
      $("#swap-out").value = ethers.formatEther(out);

      const rin = reserveIn();
      const rout = reserveOut();
      if (rin > 0n && rout > 0n) {
        const rate = Number(ethers.formatEther(rout)) / Number(ethers.formatEther(rin));
        $("#meta-rate").textContent = "1 " + inSym() + " = " + rate.toFixed(4) + " " + outSym();
        const impact = Number(ethers.formatEther(amountIn)) / Number(ethers.formatEther(rin)) * 100;
        $("#meta-impact").textContent = impact.toFixed(2) + "%";
        const minOut = (out * 995n) / 1000n;
        $("#meta-min").textContent = fmtUnits(minOut).short + " " + outSym();
      }
    } catch (err) {
      console.warn("quote:", err);
    }
  }

  /* ---------------- liquidity ---------------- */

  async function refreshLiquidity() {
    if (!account) {
      $("#liq-lp-bal").textContent = "—";
      return;
    }
    try {
      if (pairRO) {
        const bal = await pairRO.balanceOf(account);
        $("#liq-lp-bal").textContent = fmtUnits(bal).short;
      }
    } catch {}
    $("#liq-preview").textContent = "share preview: —";
  }

  async function previewAdd() {
    const a = $("#liq-gld").value;
    const b = $("#liq-usd").value;
    if (!a || !b || Number(a) <= 0 || Number(b) <= 0) {
      $("#liq-preview").textContent = "share preview: enter both amounts";
      return;
    }
    try {
      const aB = ethers.parseEther(a);
      const bB = ethers.parseEther(b);
      let lp;
      if (lpSupply === 0n || reserves.a === 0n) {
        lp = isqrt(aB * bB);
      } else {
        const byA = (aB * lpSupply) / reserves.a;
        const byB = (bB * lpSupply) / reserves.b;
        lp = byA < byB ? byA : byB;
      }
      const share = lpSupply > 0n ? Number((lp * 10000n) / (lpSupply + lp)) / 100 : 100;
      $("#liq-preview").textContent = "≈ " + fmtUnits(lp).short + " LP · " + share.toFixed(2) + "% of pool";
    } catch {
      $("#liq-preview").textContent = "share preview: —";
    }
  }

  function isqrt(n) {
    if (n < 2n) return n;
    let x = n;
    let y = (x + 1n) / 2n;
    while (y < x) {
      x = y;
      y = (x + n / x) / 2n;
    }
    return x;
  }

  async function previewRemove() {
    const lpStr = $("#liq-lp").value;
    if (!lpStr || Number(lpStr) <= 0 || lpSupply === 0n) {
      $("#rm-preview").textContent = "you receive: —";
      return;
    }
    const lp = ethers.parseEther(lpStr);
    const a = (lp * reserves.a) / lpSupply;
    const b = (lp * reserves.b) / lpSupply;
    $("#rm-preview").textContent = "you receive: " + fmtUnits(a).short + " " + symA + " + " + fmtUnits(b).short + " " + symB;
  }

  async function refreshPosition() {
    if (!account || !pairRO) {
      ["pos-lp", "pos-share", "pos-under"].forEach((id) => ($("#" + id).textContent = "—"));
      return;
    }
    try {
      const bal = await pairRO.balanceOf(account);
      $("#pos-lp").textContent = fmtUnits(bal).short;
      const share = lpSupply > 0n ? Number((bal * 10000n) / lpSupply) / 100 : 0;
      $("#pos-share").textContent = share.toFixed(4) + "%";
      const a = (bal * reserves.a) / (lpSupply || 1n);
      const b = (bal * reserves.b) / (lpSupply || 1n);
      $("#pos-under").textContent = fmtUnits(a).short + " " + symA + " + " + fmtUnits(b).short + " " + symB;
    } catch {}
  }

  /* ---------------- events ---------------- */

  async function refreshEvents() {
    const list = $("#ev-list");
    if (!pairRO) {
      list.innerHTML = '<p class="muted center" style="padding:20px 0">Deploy the AMM to see activity</p>';
      return;
    }
    try {
      const latest = await readProvider.getBlockNumber();
      const fromBlock = Math.max(0, latest - (cfg.eventLookbackBlocks || 50000));
      const logs = await readProvider.getLogs({ address: pairAddress, fromBlock, toBlock: latest });
      const decoded = logs
        .map((l) => {
          try {
            return { ...ifaceP.parseLog({ topics: l.topics, data: l.data }), blockNumber: Number(l.blockNumber), index: Number(l.index), tx: l.transactionHash };
          } catch {
            return null;
          }
        })
        .filter(Boolean)
        .sort((a, b) => (b.blockNumber - a.blockNumber) || (b.index - a.index))
        .slice(0, 12);

      if (decoded.length === 0) {
        list.innerHTML = '<p class="muted center" style="padding:20px 0">No events in the lookback window</p>';
      } else {
        list.innerHTML = decoded.map(renderEvent).join("");
      }
      $("#events-note").textContent = "latest " + decoded.length + " events · block " + latest;
    } catch (err) {
      list.innerHTML = '<p class="muted center" style="padding:20px 0">Could not load events</p>';
      console.warn("events:", err);
    }
  }

  function renderEvent(ev) {
    let detail = "";
    if (ev.name === "Swap") {
      const a0 = ev.args.amount0Out > 0n ? fmtUnits(ev.args.amount0Out).short + " " + symA + " out" : fmtUnits(ev.args.amount0In ?? 0n).short;
      detail = ev.args.amount0Out > 0n
        ? fmtUnits(ev.args.amount0Out).short + " " + symA + " → " + addrLink(ev.args.to)
        : fmtUnits(ev.args.amount1Out).short + " " + symB + " → " + addrLink(ev.args.to);
    } else if (ev.name === "Mint") {
      detail = "liquidity added: " + fmtUnits(ev.args.amount0).short + " " + symA + " + " + fmtUnits(ev.args.amount1).short + " " + symB;
    } else if (ev.name === "Burn") {
      detail = "liquidity removed: " + fmtUnits(ev.args.amount0).short + " " + symA + " + " + fmtUnits(ev.args.amount1).short + " " + symB;
    } else if (ev.name === "Sync") {
      detail = "reserves synced: " + fmtUnits(ev.args.reserve0).short + " " + symA + " / " + fmtUnits(ev.args.reserve1).short + " " + symB;
    } else {
      detail = Object.entries(ev.args).map(([k, v]) => k + ": " + shortAddr(String(v))).join(" · ");
    }
    const tx = explorerLink("/tx/" + ev.tx);
    return (
      '<div class="ev-item" style="animation-delay:' + Math.min(ev.blockNumber % 10 * 35, 320) + 'ms">' +
      '<span class="ev-tag ev-' + ev.name + '">' + ev.name + "</span>" +
      '<span class="ev-detail mono">' + detail + "</span>" +
      '<span class="mono muted">#' + ev.blockNumber + "</span>" +
      (tx ? '<a href="' + tx + '" target="_blank" rel="noopener" class="mono" style="color:#f59e0b;text-decoration:none">↗</a>' : "") +
      "</div>"
    );
  }

  /* ---------------- actions ---------------- */

  function bindUi() {
    $("#btn-connect").addEventListener("click", connect);
    $("#btn-settings").addEventListener("click", () => { $("#settings-panel").hidden = !$("#settings-panel").hidden; });
    $("#btn-cancel-settings").addEventListener("click", () => { $("#settings-panel").hidden = true; });
    $("#btn-save-settings").addEventListener("click", saveSettings);
    $("#btn-refresh-events").addEventListener("click", refreshEvents);

    $("#form-setup").addEventListener("submit", (e) => {
      e.preventDefault();
      const addr = $("#setup-address").value.trim();
      if (!ethers.isAddress(addr)) return toast("That does not look like a valid address", "error");
      routerAddress = ethers.getAddress(addr);
      localStorage.setItem(LS_ADDRESS, routerAddress);
      location.reload();
    });

    // swap
    $("#swap-in").addEventListener("input", computeOut);
    $("#btn-direction").addEventListener("click", () => {
      direction = !direction;
      const btn = $("#btn-direction");
      btn.classList.add("flipped");
      setTimeout(() => btn.classList.remove("flipped"), 450);
      $("#swap-in").value = "";
      $("#swap-out").value = "";
      refreshSwapPreview();
    });
    $("#btn-max").addEventListener("click", async () => {
      if (!account) return toast("Connect your wallet first", "error");
      try {
        const bal = await inTok().balanceOf(account);
        $("#swap-in").value = ethers.formatEther(bal);
        computeOut();
      } catch (err) {
        toast("⚠ " + decodeError(err), "error");
      }
    });
    $("#btn-swap").addEventListener("click", async () => {
      try {
        await requireReady();
        const amtStr = $("#swap-in").value;
        if (!amtStr || Number(amtStr) <= 0) return toast("Enter an amount to swap", "error");
        const amountIn = ethers.parseEther(amtStr);
        const path = [inAddr(), outAddr()];
        const outs = await routerRO.getAmountsOut(amountIn, path);
        const minOut = (outs[outs.length - 1] * 995n) / 1000n;

        const tok = new ethers.Contract(inAddr(), ABI_T, signer);
        const allowance = await tok.allowance(account, routerAddress);
        if (allowance < amountIn) {
          const ap = await tok.approve(routerAddress, amountIn);
          toast("⏳ Approve submitted — " + txLink(ap.hash), "info", 12000);
          await ap.wait();
        }
        await send(
          routerRW.swapExactTokensForTokens(amountIn, minOut, path, account, DEADLINE()),
          "Swapped"
        );
        $("#swap-in").value = "";
        $("#swap-out").value = "";
      } catch (err) {
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    // liquidity segmented control
    document.querySelectorAll(".seg-btn").forEach((btn) => {
      btn.addEventListener("click", () => {
        document.querySelectorAll(".seg-btn").forEach((b) => b.classList.remove("active"));
        btn.classList.add("active");
        $("#panel-add").hidden = btn.dataset.mode !== "add";
        $("#panel-remove").hidden = btn.dataset.mode !== "remove";
      });
    });

    // add liquidity
    $("#liq-gld").addEventListener("input", previewAdd);
    $("#liq-usd").addEventListener("input", previewAdd);
    $("#btn-add-liq").addEventListener("click", async () => {
      try {
        await requireReady();
        const a = $("#liq-gld").value;
        const b = $("#liq-usd").value;
        if (!a || !b || Number(a) <= 0 || Number(b) <= 0) return toast("Enter both amounts", "error");
        const aB = ethers.parseEther(a);
        const bB = ethers.parseEther(b);
        for (const [tokAddr, amt] of [[addrA, aB], [addrB, bB]]) {
          const tok = new ethers.Contract(tokAddr, ABI_T, signer);
          const allowance = await tok.allowance(account, routerAddress);
          if (allowance < amt) {
            const ap = await tok.approve(routerAddress, amt);
            toast("⏳ Approve submitted — " + txLink(ap.hash), "info", 12000);
            await ap.wait();
          }
        }
        await send(
          routerRW.addLiquidity(addrA, addrB, aB, bB, (aB * 995n) / 1000n, (bB * 995n) / 1000n, account, DEADLINE()),
          "Liquidity added"
        );
        $("#liq-gld").value = "";
        $("#liq-usd").value = "";
      } catch (err) {
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    // remove liquidity
    $("#liq-lp").addEventListener("input", previewRemove);
    $("#btn-lp-max").addEventListener("click", async () => {
      if (!account || !pairRO) return toast("Connect your wallet first", "error");
      const bal = await pairRO.balanceOf(account);
      $("#liq-lp").value = ethers.formatEther(bal);
      previewRemove();
    });
    $("#btn-remove-liq").addEventListener("click", async () => {
      try {
        await requireReady();
        const lpStr = $("#liq-lp").value;
        if (!lpStr || Number(lpStr) <= 0) return toast("Enter an LP amount", "error");
        const lp = ethers.parseEther(lpStr);
        const a = (lp * reserves.a) / (lpSupply || 1n);
        const b = (lp * reserves.b) / (lpSupply || 1n);
        // the router pulls LP tokens via transferFrom → approve the pair (LP) first
        const lpTok = new ethers.Contract(pairAddress, ABI_T, signer);
        const allowance = await lpTok.allowance(account, routerAddress);
        if (allowance < lp) {
          const ap = await lpTok.approve(routerAddress, lp);
          toast("⏳ LP approve submitted — " + txLink(ap.hash), "info", 12000);
          await ap.wait();
        }
        await send(
          routerRW.removeLiquidity(addrA, addrB, lp, (a * 995n) / 1000n, (b * 995n) / 1000n, account, DEADLINE()),
          "Liquidity removed"
        );
        $("#liq-lp").value = "";
      } catch (err) {
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    // live refresh
    setInterval(() => { if (routerRO) refreshPool(true); }, 15000);
  }

  async function requireReady() {
    if (!routerRO || !routerAddress) {
      const e = new Error("Configure the router address first");
      e.__handled = true;
      toast("Configure the router address first (Settings or the banner above)", "error");
      throw e;
    }
    if (!signer) {
      const e = new Error("Connect your wallet first");
      e.__handled = true;
      toast("Connect your wallet first", "error");
      throw e;
    }
    if (!pairRO) await discoverPool();
    if (!routerRW) routerRW = new ethers.Contract(routerAddress, ABI_R, signer);
  }

  async function send(txPromise, label) {
    const tx = await txPromise;
    toast("⏳ " + label + " submitted — " + txLink(tx.hash), "info", 12000);
    await tx.wait();
    toast("✅ " + label + " confirmed — " + txLink(tx.hash), "success", 9000);
    await refreshAll();
  }

  /* ---------------- settings ---------------- */

  function saveSettings() {
    const addr = $("#set-router-address").value.trim();
    if (addr && !ethers.isAddress(addr)) return toast("Invalid router address", "error");
    if (addr) {
      routerAddress = ethers.getAddress(addr);
      localStorage.setItem(LS_ADDRESS, routerAddress);
    } else {
      localStorage.removeItem(LS_ADDRESS);
    }
    localStorage.setItem(LS_CHAIN, $("#set-chain").value);
    location.reload();
  }

  /* ---------------- boot ---------------- */

  document.addEventListener("DOMContentLoaded", init);
})();
