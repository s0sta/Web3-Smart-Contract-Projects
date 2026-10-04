/* ============================================================
   Murabaha dApp — application logic
   ethers.js v6 (UMD global), no build step.
   ============================================================ */

"use strict";

(function () {
  const $ = (s) => document.querySelector(s);
  const cfg = window.APP_CONFIG || {};
  const ABI_M = window.MURABAHA_ABI || [];
  const ABI_S = window.MURABAHA_STABLE_ABI || [];

  const LS_ADDRESS = "murabaha.bookAddress";
  const LS_CHAIN = "murabaha.chainId";

  /* ---------------- state ---------------- */
  let ifaceM = null;
  let bookAddress = localStorage.getItem(LS_ADDRESS) || cfg.bookAddress || "";
  let chainIdPref = Number(localStorage.getItem(LS_CHAIN) || cfg.defaultChainId);
  let readProvider = null;
  let walletProvider = null;
  let signer = null;
  let account = null;
  let bookRO = null;
  let bookRW = null;
  let stableTok = null;
  let chainId = null;
  let rpcFailures = 0;

  const STATUS_NAMES = ["Requested", "Approved", "Purchased", "Delivered", "Repaying", "Settled", "Defaulted", "Rejected"];

  /* ---------------- helpers ---------------- */

  function chainCfg(id) {
    return cfg.chains[id] || { name: "Unknown network", short: "unknown", rpc: null, explorer: null, currency: "ETH" };
  }
  function rpcFor(id) { return chainCfg(id).rpc || "https://ethereum-rpc.publicnode.com"; }
  function fallbackRpc(id) { return (chainCfg(id).rpcFallbacks || [])[rpcFailures % (chainCfg(id).rpcFallbacks?.length || 1)]; }
  function rebuildReadProvider() {
    const rpc = rpcFailures > 0 ? fallbackRpc(chainId ?? chainIdPref) : rpcFor(chainId ?? chainIdPref);
    readProvider = new ethers.JsonRpcProvider(rpc);
    bookRO = new ethers.Contract(bookAddress, ABI_M, readProvider);
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
    if (err.data && ifaceM) {
      try { const e = ifaceM.parseError(err.data); if (e) return e.name; } catch {}
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
    ifaceM = new ethers.Interface(ABI_M);

    try {
      const res = await fetch("api/config.php", { cache: "no-store" });
      if (res.ok) {
        const data = await res.json();
        if (data && data.bookAddress && !localStorage.getItem(LS_ADDRESS)) bookAddress = data.bookAddress;
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
    bookAddress = localStorage.getItem(LS_ADDRESS) || bookAddress || "";

    readProvider = new ethers.JsonRpcProvider(rpcFor(chainIdPref));
    chainId = chainIdPref;

    if (bookAddress && ethers.isAddress(bookAddress)) {
      bookRO = new ethers.Contract(bookAddress, ABI_M, readProvider);
    } else bookRO = null;
    bookRW = null;

    $("#setup-banner").hidden = !!bookRO;
    $("#chain-badge").textContent = chainCfg(chainIdPref).name;
    $("#chain-badge").classList.toggle("ok", !!chainCfg(chainIdPref).rpc);
    $("#footer-address").textContent = bookRO ? shortAddr(bookAddress) : "not configured";
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
      account = null; signer = null; bookRW = null;
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
    await refreshBook();
  }

  function renderWalletButton() {
    const btn = $("#btn-connect");
    btn.textContent = account ? shortAddr(account) : "Connect Wallet";
    btn.title = account || "";
  }

  async function refreshBook(silent) {
    if (!bookRO) return;
    try {
      if (!stableTok) stableTok = new ethers.Contract(await bookRO.paymentToken(), ABI_S, readProvider);
      let count = 0;
      try { while (true) { await bookRO.trades(count); count++; } } catch {}

      const rows = [];
      for (let i = count - 1; i >= 0 && i >= count - 15; i--) {
        const t = await bookRO.trades(i);
        const status = Number(t.status);
        const pct = t.installments > 0n ? Number((t.paidInstallments * 10000n) / t.installments) / 100 : 0;
        const missed = await bookRO.missedInstallments(i);
        rows.push(
          '<div class="trade">' +
          '<div class="trade-top"><span class="trade-id">Trade #' + i + "</span>" +
          '<span class="status-pill st-' + status + '">' + STATUS_NAMES[status] + "</span>" +
          '<span class="muted small" style="margin-left:auto">' + fmtUnits(t.costPrice + t.markup).short + " AED-S total</span></div>" +
          '<p class="trade-asset">' + (t.assetDescription || "—") + "</p>" +
          '<div class="trade-meta"><span>by ' + shortAddr(t.buyer) + "</span>" +
          '<span>supplier ' + shortAddr(t.supplier) + "</span>" +
          '<span>installments ' + t.paidInstallments.toString() + "/" + t.installments.toString() + "</span>" +
          '<span>missed ' + missed.toString() + "</span>" +
          '<span>fees→charity ' + fmtUnits(t.lateFeeCharged).short + "</span></div>" +
          '<div class="trade-bar"><span style="width:' + Math.min(pct, 100) + '%"></span></div>' +
          "</div>"
        );
      }
      $("#trade-list").innerHTML = rows.join("") || '<p class="muted">no trades yet</p>';
      $("#book-note").textContent = count === 0 ? "no trades yet" : count + " on-chain";
    } catch (err) {
      console.warn("book:", err);
      const fallbacks = chainCfg(chainId ?? chainIdPref).rpcFallbacks || [];
      if (rpcFailures < fallbacks.length) {
        rpcFailures++;
        rebuildReadProvider();
        await refreshBook(silent);
        return;
      }
      rpcFailures = 0;
      rebuildReadProvider();
      if (!silent) toast("Could not read the book — " + (err.shortMessage || err.message || ""), "error", 9000);
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
      bookAddress = ethers.getAddress(addr);
      localStorage.setItem(LS_ADDRESS, bookAddress);
      location.reload();
    });

    $("#form-request").addEventListener("submit", async (e) => {
      e.preventDefault();
      try {
        await requireSigner();
        const supplier = $("#rq-supplier").value.trim();
        const guarantor = $("#rq-guarantor").value.trim();
        const cost = $("#rq-cost").value;
        const markup = $("#rq-markup").value;
        const installments = $("#rq-installments").value;
        const asset = $("#rq-asset").value.trim() || "trade";
        if (!ethers.isAddress(supplier) || !ethers.isAddress(guarantor)) return toast("Invalid supplier/guarantor address", "error");
        if (!cost || !markup || !installments || Number(installments) < 1) return toast("Fill cost, markup and installments", "error");
        const invoiceHash = ethers.id("invoice-" + Date.now());
        await send(
          bookRW.requestTrade(ethers.getAddress(supplier), ethers.getAddress(guarantor), ethers.parseEther(cost), ethers.parseEther(markup), BigInt(installments), 30n * 86400n, invoiceHash, asset),
          "Trade requested"
        );
        ["rq-supplier", "rq-guarantor", "rq-cost", "rq-markup", "rq-installments", "rq-asset"].forEach((id) => { $("#" + id).value = ""; });
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    const act = async (fn, label, needsFunds) => {
      try {
        await requireSigner();
        const tid = BigInt($("#act-trade").value || "0");
        if (needsFunds) {
          const t = await bookRO.trades(tid);
          const amount = t.installmentAmount * (1n + BigInt(await bookRO.missedInstallments(tid)));
          const fee = t.installmentAmount * BigInt(await bookRO.latePenaltyBps()) * BigInt(await bookRO.missedInstallments(tid)) / 10000n;
          const total = amount + fee;
          const allowance = await stableTok.allowance(account, bookAddress);
          if (allowance < total) {
            const ap = await stableTok.connect(signer).approve(bookAddress, total * 2n);
            toast("⏳ Approve submitted — " + txLink(ap.hash), "info", 12000);
            await ap.wait();
          }
        }
        await send(fn(tid), label);
        $("#act-trade").value = "";
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    };

    $("#btn-approve").addEventListener("click", () => act((id) => bookRW.approveTrade(id), "Approved"));
    $("#btn-purchase").addEventListener("click", () => act((id) => bookRW.purchaseAsset(id), "Supplier paid"));
    $("#btn-deliver").addEventListener("click", () => act((id) => bookRW.confirmDelivery(id), "Delivery confirmed"));
    $("#btn-installment").addEventListener("click", () => act((id) => bookRW.payInstallment(id), "Installment paid", true));
    $("#btn-settle").addEventListener("click", () => act((id) => bookRW.settleEarly(id), "Settled early", true));
    $("#btn-default").addEventListener("click", () => act((id) => bookRW.markDefault(id), "Marked default"));
    $("#btn-recover").addEventListener("click", () => act((id) => bookRW.recover(id, account, 0n), "Recovered"));

    setInterval(() => { if (bookRO) refreshBook(); }, 30000);
  }

  async function requireSigner() {
    if (!bookRO || !bookAddress) {
      const e = new Error("no book"); e.__handled = true;
      toast("Configure the book address first (Settings or the banner above)", "error");
      throw e;
    }
    if (!signer) {
      const e = new Error("no signer"); e.__handled = true;
      toast("Connect your wallet first", "error");
      throw e;
    }
    if (!bookRW) bookRW = new ethers.Contract(bookAddress, ABI_M, signer);
  }

  async function send(txPromise, label) {
    const tx = await txPromise;
    toast("⏳ " + label + " submitted — " + txLink(tx.hash), "info", 12000);
    await tx.wait();
    toast("✅ " + label + " confirmed — " + txLink(tx.hash), "success", 9000);
    await refreshAll();
  }

  function saveSettings() {
    const addr = $("#set-book-address").value.trim();
    if (addr && !ethers.isAddress(addr)) return toast("Invalid book address", "error");
    if (addr) {
      bookAddress = ethers.getAddress(addr);
      localStorage.setItem(LS_ADDRESS, bookAddress);
    } else localStorage.removeItem(LS_ADDRESS);
    localStorage.setItem(LS_CHAIN, $("#set-chain").value);
    location.reload();
  }

  document.addEventListener("DOMContentLoaded", init);
})();
