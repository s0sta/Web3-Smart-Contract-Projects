/* ============================================================
   Zakat Engine dApp — application logic
   ethers.js v6 (UMD global), no build step.
   ============================================================ */

"use strict";

(function () {
  const $ = (s) => document.querySelector(s);
  const cfg = window.APP_CONFIG || {};
  const ABI_E = window.ZAKAT_ENGINE_ABI || [];
  const ABI_R = window.ZAKAT_REGISTRY_ABI || [];
  const ABI_S = window.ZAKAT_STABLE_ABI || [];

  const LS_ADDRESS = "zakat.engineAddress";
  const LS_CHAIN = "zakat.chainId";

  /* ---------------- state ---------------- */
  let ifaceE = null;
  let engineAddress = localStorage.getItem(LS_ADDRESS) || cfg.engineAddress || "";
  let chainIdPref = Number(localStorage.getItem(LS_CHAIN) || cfg.defaultChainId);
  let readProvider = null;
  let walletProvider = null;
  let signer = null;
  let account = null;
  let engineRO = null;
  let engineRW = null;
  let registryRO = null;
  let registryRW = null;
  let stableTok = null;
  let chainId = null;
  let rpcFailures = 0;

  /* ---------------- helpers ---------------- */

  function chainCfg(id) {
    return cfg.chains[id] || { name: "Unknown network", short: "unknown", rpc: null, explorer: null, currency: "ETH" };
  }
  function rpcFor(id) { return chainCfg(id).rpc || "https://ethereum-rpc.publicnode.com"; }
  function fallbackRpc(id) { return (chainCfg(id).rpcFallbacks || [])[rpcFailures % (chainCfg(id).rpcFallbacks?.length || 1)]; }
  function rebuildReadProvider() {
    const rpc = rpcFailures > 0 ? fallbackRpc(chainId ?? chainIdPref) : rpcFor(chainId ?? chainIdPref);
    readProvider = new ethers.JsonRpcProvider(rpc);
    engineRO = new ethers.Contract(engineAddress, ABI_E, readProvider);
    registryRO = null; stableTok = null;
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
    if (err.data && ifaceE) {
      try { const e = ifaceE.parseError(err.data); if (e) return e.name; } catch {}
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
    ifaceE = new ethers.Interface(ABI_E);

    try {
      const res = await fetch("api/config.php", { cache: "no-store" });
      if (res.ok) {
        const data = await res.json();
        if (data && data.engineAddress && !localStorage.getItem(LS_ADDRESS)) engineAddress = data.engineAddress;
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
    engineAddress = localStorage.getItem(LS_ADDRESS) || engineAddress || "";

    readProvider = new ethers.JsonRpcProvider(rpcFor(chainIdPref));
    chainId = chainIdPref;

    if (engineAddress && ethers.isAddress(engineAddress)) {
      engineRO = new ethers.Contract(engineAddress, ABI_E, readProvider);
    } else engineRO = null;
    engineRW = null; registryRO = null;

    $("#setup-banner").hidden = !!engineRO;
    $("#chain-badge").textContent = chainCfg(chainIdPref).name;
    $("#chain-badge").classList.toggle("ok", !!chainCfg(chainIdPref).rpc);
    $("#footer-address").textContent = engineRO ? shortAddr(engineAddress) : "not configured";
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
      account = null; signer = null; engineRW = null; registryRW = null;
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
    await refreshEngine();
  }

  function renderWalletButton() {
    const btn = $("#btn-connect");
    btn.textContent = account ? shortAddr(account) : "Connect Wallet";
    btn.title = account || "";
  }

  async function refreshEngine(silent) {
    if (!engineRO) return;
    try {
      if (!registryRO) registryRO = new ethers.Contract(await engineRO.registry(), ABI_R, readProvider);
      if (!stableTok) stableTok = new ethers.Contract(await engineRO.paymentToken(), ABI_S, readProvider);

      const [fund, collected, distributed, nisab, paused] = await Promise.all([
        engineRO.zakatFund(),
        engineRO.totalCollected(),
        engineRO.totalDistributed(),
        engineRO.nisab(),
        engineRO.paused(),
      ]);
      $("#strip-fund").textContent = fmtUnits(fund) + " AED-S";
      $("#strip-collected").textContent = fmtUnits(collected) + " AED-S";
      $("#strip-distributed").textContent = fmtUnits(distributed) + " AED-S";
      $("#strip-nisab").textContent = fmtUnits(nisab) + " AED-S";
      $("#strip-status").innerHTML = paused
        ? '<span class="status-pill status-bad">PAUSED</span>'
        : '<span class="status-pill status-ok">ACTIVE</span>';

      // the eight gates
      let gates = "";
      for (let i = 0; i < 8; i++) {
        const name = await registryRO.asnafName(i);
        const bps = await registryRO.allocations(i);
        gates +=
          '<div class="asnaf-cell"><div class="asnaf-name">' + (i + 1) + ". " + name + "</div>" +
          '<div class="asnaf-bps">' + (Number(bps) / 100).toFixed(1) + "%</div>" +
          '<div class="asnaf-bar"><span style="width:' + Math.min(Number(bps) / 100, 100) + '%"></span></div></div>';
      }
      $("#asnaf-grid").innerHTML = gates;

      // payer panel
      if (account) {
        const p = await engineRO.payers(account);
        $("#pay-wealth").textContent = fmtUnits(p.declaredWealth) + " AED-S";
        $("#pay-hawl").textContent = Number(p.hawlStart) === 0 ? "not started" : "started";
        $("#pay-due").textContent = fmtUnits(await engineRO.zakatDue(account)) + " AED-S";
        $("#pay-paid").textContent = fmtUnits(p.zakatPaid) + " AED-S";
      } else {
        $("#pay-wealth").textContent = "—";
        $("#pay-due").textContent = "—";
      }

      // disbursements
      let rows = "";
      let count = 0;
      try { while (true) { await engineRO.disbursements(count); count++; } } catch {}
      const isCommittee = account ? await engineRO.hasRole(engineRO.COMMITTEE_ROLE(), account) : false;
      let open = 0;
      for (let i = count - 1; i >= 0 && i >= count - 12; i--) {
        const d = await engineRO.disbursements(i);
        if (!d.executed) open++;
        rows +=
          '<div class="disb-row"><span class="mono">#' + i + "</span>" +
          '<span class="muted small">asnaf ' + d.asnafId.toString() + " · recipient #" + d.recipientId.toString() + "</span>" +
          '<span class="disb-right">' + fmtUnits(d.amount).short + " · " + d.approvals.toString() + "/2 ✓" + (d.executed ? " · paid" : "") + "</span>" +
          (isCommittee && !d.executed ? '<div class="disb-vote"><button class="btn btn-ghost btn-sm" data-action="vote" data-id="' + i + '">Approve</button></div>' : "") +
          "</div>";
      }
      $("#disb-list").innerHTML = rows || '<p class="muted">no proposals yet</p>';
      $("#disb-note").textContent = open === 0 ? "no open proposals" : open + " pending";
    } catch (err) {
      console.warn("engine:", err);
      const fallbacks = chainCfg(chainId ?? chainIdPref).rpcFallbacks || [];
      if (rpcFailures < fallbacks.length) {
        rpcFailures++;
        rebuildReadProvider();
        await refreshEngine(silent);
        return;
      }
      rpcFailures = 0;
      rebuildReadProvider();
      if (!silent) toast("Could not read the engine — " + (err.shortMessage || err.message || ""), "error", 9000);
    }
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
      engineAddress = ethers.getAddress(addr);
      localStorage.setItem(LS_ADDRESS, engineAddress);
      location.reload();
    });

    $("#btn-declare").addEventListener("click", async () => {
      try {
        await requireSigner();
        const amt = $("#wealth-amount").value;
        if (!amt || Number(amt) <= 0) return toast("Wealth must be > 0", "error");
        await send(engineRW.declareWealth(ethers.parseEther(amt)), "Wealth declared");
        $("#wealth-amount").value = "";
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-pay").addEventListener("click", async () => {
      try {
        await requireSigner();
        const due = await engineRO.zakatDue(account);
        if (due === 0n) return toast("Nothing is due yet (nisab + hawl required)", "info");
        const allowance = await stableTok.allowance(account, engineAddress);
        if (allowance < due) {
          const ap = await stableTok.connect(signer).approve(engineAddress, due);
          toast("⏳ Approve submitted — " + txLink(ap.hash), "info", 12000);
          await ap.wait();
        }
        await send(engineRW.payZakat(), "Zakat paid — jazaak Allah khair");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-register").addEventListener("click", async () => {
      try {
        await requireSigner();
        const addr = $("#rcpt-account").value.trim();
        if (!ethers.isAddress(addr)) return toast("Invalid recipient address", "error");
        const proof = ethers.id("proof-" + addr.toLowerCase() + "-" + Date.now());
        await send(registryRW.registerRecipient(ethers.getAddress(addr), $("#rcpt-asnaf").value, proof), "Recipient registered");
        $("#rcpt-account").value = "";
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-propose").addEventListener("click", async () => {
      try {
        await requireSigner();
        const rid = $("#prop-recipient").value;
        const amt = $("#prop-amount").value;
        if (rid === "" || Number(rid) < 0) return toast("Pick a recipient id", "error");
        if (!amt || Number(amt) <= 0) return toast("Amount must be > 0", "error");
        await send(engineRW.proposeDisbursement(BigInt(rid), ethers.parseEther(amt)), "Disbursement proposed");
        $("#prop-recipient").value = ""; $("#prop-amount").value = "";
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#disb-list").addEventListener("click", async (e) => {
      const btn = e.target.closest("[data-action='vote']");
      if (!btn) return;
      try {
        await requireSigner();
        await send(engineRW.voteDisbursement(BigInt(btn.dataset.id), true), "Voted");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    setInterval(() => { if (engineRO) refreshEngine(); }, 30000);
  }

  async function requireSigner() {
    if (!engineRO || !engineAddress) {
      const e = new Error("no engine"); e.__handled = true;
      toast("Configure the engine address first (Settings or the banner above)", "error");
      throw e;
    }
    if (!signer) {
      const e = new Error("no signer"); e.__handled = true;
      toast("Connect your wallet first", "error");
      throw e;
    }
    if (!engineRW) engineRW = new ethers.Contract(engineAddress, ABI_E, signer);
    if (!registryRW) registryRW = new ethers.Contract(cfg.registryAddress, ABI_R, signer);
  }

  async function send(txPromise, label) {
    const tx = await txPromise;
    toast("⏳ " + label + " submitted — " + txLink(tx.hash), "info", 12000);
    await tx.wait();
    toast("✅ " + label + " confirmed — " + txLink(tx.hash), "success", 9000);
    await refreshAll();
  }

  function saveSettings() {
    const addr = $("#set-engine-address").value.trim();
    if (addr && !ethers.isAddress(addr)) return toast("Invalid engine address", "error");
    if (addr) {
      engineAddress = ethers.getAddress(addr);
      localStorage.setItem(LS_ADDRESS, engineAddress);
    } else localStorage.removeItem(LS_ADDRESS);
    localStorage.setItem(LS_CHAIN, $("#set-chain").value);
    location.reload();
  }

  document.addEventListener("DOMContentLoaded", init);
})();
