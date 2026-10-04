/* ============================================================
   Takaful dApp — application logic
   ethers.js v6 (UMD global), no build step.
   ============================================================ */

"use strict";

(function () {
  const $ = (s) => document.querySelector(s);
  const cfg = window.APP_CONFIG || {};
  const ABI_P = window.TAKAFUL_POOL_ABI || [];
  const ABI_S = window.TAKAFUL_STABLE_ABI || [];

  const LS_ADDRESS = "takaful.poolAddress";
  const LS_CHAIN = "takaful.chainId";

  /* ---------------- state ---------------- */
  let ifaceP = null;
  let poolAddress = localStorage.getItem(LS_ADDRESS) || cfg.poolAddress || "";
  let chainIdPref = Number(localStorage.getItem(LS_CHAIN) || cfg.defaultChainId);
  let readProvider = null;
  let walletProvider = null;
  let signer = null;
  let account = null;
  let poolRO = null;
  let poolRW = null;
  let stableTok = null;
  let chainId = null;
  let rpcFailures = 0;
  let poolCount = 0;
  let policyCount = 0;
  let claimCount = 0;

  /* ---------------- helpers ---------------- */

  function chainCfg(id) {
    return cfg.chains[id] || { name: "Unknown network", short: "unknown", rpc: null, explorer: null, currency: "ETH" };
  }
  function rpcFor(id) { return chainCfg(id).rpc || "https://ethereum-rpc.publicnode.com"; }
  function fallbackRpc(id) { return (chainCfg(id).rpcFallbacks || [])[rpcFailures % (chainCfg(id).rpcFallbacks?.length || 1)]; }
  function rebuildReadProvider() {
    const rpc = rpcFailures > 0 ? fallbackRpc(chainId ?? chainIdPref) : rpcFor(chainId ?? chainIdPref);
    readProvider = new ethers.JsonRpcProvider(rpc);
    poolRO = new ethers.Contract(poolAddress, ABI_P, readProvider);
    stableTok = null;
  }

  function shortAddr(a) {
    if (!a) return "—";
    a = String(a);
    return a.length > 12 ? a.slice(0, 6) + "…" + a.slice(-4) : a;
  }
  function fmtUnits(bn, dec = 18) {
    try {
      const n = Number(ethers.formatUnits(bn, dec));
      return n >= 1e6 ? new Intl.NumberFormat("en", { notation: "compact", maximumFractionDigits: 2 }).format(n)
        : new Intl.NumberFormat("en", { maximumFractionDigits: 2 }).format(n);
    } catch { return "—"; }
  }
  function explorerLink(path) {
    const ex = chainCfg(chainId ?? chainIdPref).explorer;
    return ex ? ex + path : null;
  }
  function txLink(hash) {
    const base = explorerLink("/tx/" + hash);
    return base ? '<a href="' + base + '" target="_blank" rel="noopener">' + shortAddr(hash) + " ↗</a>" : shortAddr(hash);
  }

  /* ---------------- toasts & errors ---------------- */

  function toast(message, type = "info", ttl = 6000) {
    const box = $("#toast-container");
    const el = document.createElement("div");
    el.className = "toast " + type;
    el.innerHTML = message;
    box.appendChild(el);
    setTimeout(() => { el.classList.add("out"); setTimeout(() => el.remove(), 300); }, ttl);
  }

  function decodeError(err) {
    if (!err) return "Unknown error";
    if (err.revert && err.revert.name) return err.revert.name;
    if (err.data && ifaceP) {
      try { const e = ifaceP.parseError(err.data); if (e) return e.name; } catch {}
    }
    if (err.shortMessage) {
      const m = err.shortMessage;
      if (m.includes("user rejected")) return "Transaction rejected in wallet";
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
    ifaceP = new ethers.Interface(ABI_P);

    try {
      const res = await fetch("api/config.php", { cache: "no-store" });
      if (res.ok) {
        const data = await res.json();
        if (data && data.poolAddress && !localStorage.getItem(LS_ADDRESS)) poolAddress = data.poolAddress;
        if (data && data.github) cfg.github = data.github;
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
        if (accts.length > 0) { account = accts[0]; signer = await walletProvider.getSigner(); }
      } catch {}
    }

    bindUi();
    await refreshAll();
  }

  function applyAddressAndChain() {
    let savedChain = Number(localStorage.getItem(LS_CHAIN) || cfg.defaultChainId);
    if (!cfg.chains[savedChain] || savedChain === 31337) {
      savedChain = cfg.defaultChainId;
      localStorage.removeItem(LS_CHAIN);
    }
    chainIdPref = savedChain;
    poolAddress = localStorage.getItem(LS_ADDRESS) || poolAddress || "";

    readProvider = new ethers.JsonRpcProvider(rpcFor(chainIdPref));
    chainId = chainIdPref;

    if (poolAddress && ethers.isAddress(poolAddress)) {
      poolRO = new ethers.Contract(poolAddress, ABI_P, readProvider);
    } else poolRO = null;
    poolRW = null;

    $("#setup-banner").hidden = !!poolRO;
    $("#chain-badge").textContent = chainCfg(chainIdPref).name;
    $("#chain-badge").classList.toggle("ok", !!chainCfg(chainIdPref).rpc);
    $("#footer-address").textContent = poolRO ? shortAddr(poolAddress) : "not configured";
    $("#footer-github").href = cfg.github || "#";
    $("#footer-explorer").href = chainCfg(chainIdPref).explorer || "#";
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

  /* ---------------- wallet ---------------- */

  async function connect() {
    if (!window.ethereum) { toast("No wallet detected — install MetaMask and refresh", "error", 9000); return; }
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
      account = null; signer = null; poolRW = null;
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
        } catch { return false; }
      }
      return false;
    }
  }

  /* ---------------- rendering ---------------- */

  async function refreshAll() {
    renderWalletButton();
    await refreshPool();
  }

  function renderWalletButton() {
    const btn = $("#btn-connect");
    btn.textContent = account ? shortAddr(account) : "Connect Wallet";
    btn.title = account || "";
  }

  async function refreshPool(silent) {
    if (!poolRO) return;
    try {
      if (!stableTok) stableTok = new ethers.Contract(await poolRO.paymentToken(), ABI_S, readProvider);

      const [balance, qard, fees, paused, totalPaid] = await Promise.all([
        stableTok.balanceOf(poolAddress),
        poolRO.qardHasanFacility(),
        poolRO.totalWakalahFees(),
        poolRO.paused(),
        (async () => {
          let total = 0n;
          for (let i = 0; i < poolCount; i++) total += (await poolRO.pools(i)).totalClaimsPaid;
          return total;
        })(),
      ]);
      $("#circle-balance").textContent = fmtUnits(balance) + " AED-S";
      $("#circle-qard").textContent = fmtUnits(qard) + " AED-S";
      $("#circle-paid").textContent = fmtUnits(totalPaid) + " AED-S";
      $("#circle-fees").textContent = fmtUnits(fees) + " AED-S";
      $("#circle-status").innerHTML = paused
        ? '<span class="status-pill status-bad">PAUSED</span>'
        : '<span class="status-pill status-ok">ACTIVE</span>';

      // pools
      let rows = "";
      poolCount = await poolCountScan();
      for (let i = 0; i < poolCount; i++) {
        const p = await poolRO.pools(i);
        rows +=
          '<div class="item-row">' +
          '<span style="font-weight:700">' + p.name + "</span>" +
          '<span class="muted small">' + fmtUnits(p.contributionAmount).short + " AED-S · limit " + fmtUnits(p.claimLimit).short + "</span>" +
          '<span class="item-right">' + fmtUnits(p.totalContributions).short + " pooled</span>" +
          '<button class="btn btn-primary btn-sm" data-action="join" data-id="' + i + '">Join</button>' +
          "</div>";
      }
      $("#pool-list").innerHTML = rows || '<p class="muted">no pools</p>';

      // policies
      let polRows = "";
      if (account) {
        for (let i = 0; i < policyCount; i++) {
          const pol = await poolRO.policies(i);
          if (pol.holder.toLowerCase() !== account.toLowerCase()) continue;
          polRows +=
            '<div class="item-row"><span class="mono">#' + i + "</span>" +
            '<span class="muted small">' + (pol.active ? "active" : "closed") + "</span>" +
            '<span class="item-right">' + fmtUnits(pol.claimed).short + " / " + fmtUnits((await poolRO.pools(pol.poolId)).claimLimit).short + " claimed</span></div>";
        }
      }
      $("#policy-list").innerHTML = polRows || '<p class="muted">connect to see your policies</p>';

      // claims committee
      let claimRows = "";
      claimCount = await claimCountScan();
      const isAssessor = account ? await poolRO.hasRole(poolRO.ASSESSOR_ROLE(), account) : false;
      let openClaims = 0;
      for (let i = 0; i < claimCount; i++) {
        const c = await poolRO.claims(i);
        if (c.decided) continue;
        openClaims++;
        claimRows +=
          '<div class="item-row"><span class="mono">#' + i + "</span>" +
          '<span class="muted small">' + fmtUnits(c.amount).short + " AED-S · " + (c.reason || "—") + "</span>" +
          '<span class="item-right">' + c.approvalsCount.toString() + "/2 ✓</span>" +
          (isAssessor ? '<div class="claim-vote"><button class="btn btn-ghost btn-sm" data-action="approve" data-id="' + i + '">Approve</button><button class="btn btn-danger btn-sm" data-action="reject" data-id="' + i + '">Reject</button></div>' : "") +
          "</div>";
      }
      $("#claim-list").innerHTML = claimRows || '<p class="muted">no open claims</p>';
      $("#committee-note").textContent = openClaims === 0 ? "no open claims" : openClaims + " pending";
    } catch (err) {
      console.warn("pool:", err);
      const fallbacks = chainCfg(chainId ?? chainIdPref).rpcFallbacks || [];
      if (rpcFailures < fallbacks.length) {
        rpcFailures++;
        rebuildReadProvider();
        await refreshPool(silent);
        return;
      }
      rpcFailures = 0;
      rebuildReadProvider();
      if (!silent) toast("Could not read the pool — " + (err.shortMessage || err.message || ""), "error", 9000);
    }
  }

  async function poolCountScan() {
    let n = 0;
    try { while (true) { await poolRO.pools(n); n++; } } catch { return n; }
  }
  async function claimCountScan() {
    let n = 0;
    try { while (true) { await poolRO.claims(n); n++; } } catch { return n; }
  }
  async function policyCountScan() {
    let n = 0;
    try { while (true) { await poolRO.policies(n); n++; } } catch { return n; }
  }

  /* ---------------- actions ---------------- */

  function bindUi() {
    $("#btn-connect").addEventListener("click", connect);
    $("#btn-settings").addEventListener("click", () => { $("#settings-panel").hidden = !$("#settings-panel").hidden; });
    $("#btn-cancel-settings").addEventListener("click", () => { $("#settings-panel").hidden = true; });
    $("#btn-save-settings").addEventListener("click", saveSettings);

    $("#form-setup").addEventListener("submit", (e) => {
      e.preventDefault();
      const addr = $("#setup-address").value.trim();
      if (!ethers.isAddress(addr)) return toast("That does not look like a valid address", "error");
      poolAddress = ethers.getAddress(addr);
      localStorage.setItem(LS_ADDRESS, poolAddress);
      location.reload();
    });

    $("#pool-list").addEventListener("click", async (e) => {
      const btn = e.target.closest("[data-action='join']");
      if (!btn) return;
      try {
        await requireSigner();
        const poolId = btn.dataset.id;
        const contribution = (await poolRO.pools(poolId)).contributionAmount;
        const allowance = await stableTok.allowance(account, poolAddress);
        if (allowance < contribution) {
          const ap = await stableTok.connect(signer).approve(poolAddress, contribution);
          toast("⏳ Approve submitted — " + txLink(ap.hash), "info", 12000);
          await ap.wait();
        }
        await send(poolRW.joinPool(poolId), "Policy issued — tabarru accepted");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-claim").addEventListener("click", async () => {
      try {
        await requireSigner();
        const pid = $("#claim-policy").value;
        const amt = $("#claim-amount").value;
        const reason = $("#claim-reason").value.trim() || "claim";
        if (pid === "" || Number(pid) < 0) return toast("Pick your policy id", "error");
        if (!amt || Number(amt) <= 0) return toast("Amount must be > 0", "error");
        await send(poolRW.fileClaim(BigInt(pid), ethers.parseEther(amt), reason), "Claim filed");
        $("#claim-policy").value = ""; $("#claim-amount").value = ""; $("#claim-reason").value = "";
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#claim-list").addEventListener("click", async (e) => {
      const btn = e.target.closest("[data-action]");
      if (!btn) return;
      try {
        await requireSigner();
        const id = BigInt(btn.dataset.id);
        const approve = btn.dataset.action === "approve";
        await send(poolRW.voteClaim(id, approve), approve ? "Claim approved" : "Claim rejected");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-qard").addEventListener("click", async () => {
      try {
        await requireSigner();
        const amt = $("#qard-amount").value;
        if (!amt || Number(amt) <= 0) return toast("Amount must be > 0", "error");
        const amount = ethers.parseEther(amt);
        const allowance = await stableTok.allowance(account, poolAddress);
        if (allowance < amount) {
          const ap = await stableTok.connect(signer).approve(poolAddress, amount);
          toast("⏳ Approve submitted — " + txLink(ap.hash), "info", 12000);
          await ap.wait();
        }
        await send(poolRW.fundQardHasan(amount), "Qard hasan funded — jazaak Allah khair");
        $("#qard-amount").value = "";
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-surplus").addEventListener("click", async () => {
      try {
        await requireSigner();
        // the operator passes the participant list — in the demo, the recent
        // policy holders from the last 20 policies are used
        const participants = [];
        const total = await policyCountScan();
        const seen = new Set();
        for (let i = Math.max(0, total - 20); i < total; i++) {
          const pol = await poolRO.policies(i);
          if (!seen.has(pol.holder.toLowerCase())) {
            seen.add(pol.holder.toLowerCase());
            participants.push(pol.holder);
          }
        }
        await send(poolRW.distributeSurplus(0, participants), "Surplus distributed");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    setInterval(() => { if (poolRO) refreshPool(); }, 30000);
  }

  async function requireSigner() {
    if (!poolRO || !poolAddress) {
      const e = new Error("no pool"); e.__handled = true;
      toast("Configure the pool address first (Settings or the banner above)", "error");
      throw e;
    }
    if (!signer) {
      const e = new Error("no signer"); e.__handled = true;
      toast("Connect your wallet first", "error");
      throw e;
    }
    if (!poolRW) poolRW = new ethers.Contract(poolAddress, ABI_P, signer);
  }

  async function send(txPromise, label) {
    const tx = await txPromise;
    toast("⏳ " + label + " submitted — " + txLink(tx.hash), "info", 12000);
    await tx.wait();
    toast("✅ " + label + " confirmed — " + txLink(tx.hash), "success", 9000);
    await refreshAll();
  }

  function saveSettings() {
    const addr = $("#set-pool-address").value.trim();
    if (addr && !ethers.isAddress(addr)) return toast("Invalid pool address", "error");
    if (addr) {
      poolAddress = ethers.getAddress(addr);
      localStorage.setItem(LS_ADDRESS, poolAddress);
    } else localStorage.removeItem(LS_ADDRESS);
    localStorage.setItem(LS_CHAIN, $("#set-chain").value);
    location.reload();
  }

  document.addEventListener("DOMContentLoaded", init);
})();
