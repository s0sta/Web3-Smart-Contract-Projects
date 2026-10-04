/* ============================================================
   Sukuk Vault dApp — application logic
   ethers.js v6 (UMD global), no build step.
   ============================================================ */

"use strict";

(function () {
  const $ = (s) => document.querySelector(s);
  const cfg = window.APP_CONFIG || {};
  const ABI_V = window.SUKUK_VAULT_ABI || [];
  const ABI_S = window.SUKUK_STABLE_ABI || [];

  const LS_ADDRESS = "sukuk.vaultAddress";
  const LS_CHAIN = "sukuk.chainId";

  /* ---------------- state ---------------- */
  let ifaceV = null;
  let vaultAddress = localStorage.getItem(LS_ADDRESS) || cfg.vaultAddress || "";
  let chainIdPref = Number(localStorage.getItem(LS_CHAIN) || cfg.defaultChainId);
  let readProvider = null;
  let walletProvider = null;
  let signer = null;
  let account = null;
  let vaultRO = null;
  let vaultRW = null;
  let stableTok = null;
  let chainId = null;
  let rpcFailures = 0;

  const SERIES_ID = 0;

  /* ---------------- helpers ---------------- */

  function chainCfg(id) {
    return cfg.chains[id] || { name: "Unknown network", short: "unknown", rpc: null, explorer: null, currency: "ETH" };
  }
  function rpcFor(id) { return chainCfg(id).rpc || "https://ethereum-rpc.publicnode.com"; }
  function fallbackRpc(id) { return (chainCfg(id).rpcFallbacks || [])[rpcFailures % (chainCfg(id).rpcFallbacks?.length || 1)]; }
  function rebuildReadProvider() {
    const rpc = rpcFailures > 0 ? fallbackRpc(chainId ?? chainIdPref) : rpcFor(chainId ?? chainIdPref);
    readProvider = new ethers.JsonRpcProvider(rpc);
    vaultRO = new ethers.Contract(vaultAddress, ABI_V, readProvider);
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
  function fmtDate(ts) {
    if (!ts || Number(ts) === 0) return "—";
    return new Date(Number(ts) * 1000).toLocaleDateString("en", { month: "short", day: "numeric", year: "numeric" });
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
    if (err.data && ifaceV) {
      try { const e = ifaceV.parseError(err.data); if (e) return e.name; } catch {}
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
    ifaceV = new ethers.Interface(ABI_V);

    try {
      const res = await fetch("api/config.php", { cache: "no-store" });
      if (res.ok) {
        const data = await res.json();
        if (data && data.vaultAddress && !localStorage.getItem(LS_ADDRESS)) vaultAddress = data.vaultAddress;
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
    vaultAddress = localStorage.getItem(LS_ADDRESS) || vaultAddress || "";

    readProvider = new ethers.JsonRpcProvider(rpcFor(chainIdPref));
    chainId = chainIdPref;

    if (vaultAddress && ethers.isAddress(vaultAddress)) {
      vaultRO = new ethers.Contract(vaultAddress, ABI_V, readProvider);
    } else vaultRO = null;
    vaultRW = null;

    $("#setup-banner").hidden = !!vaultRO;
    $("#chain-badge").textContent = chainCfg(chainIdPref).name;
    $("#chain-badge").classList.toggle("ok", !!chainCfg(chainIdPref).rpc);
    $("#footer-address").textContent = vaultRO ? shortAddr(vaultAddress) : "not configured";
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
      account = null; signer = null; vaultRW = null;
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
    await refreshVault();
  }

  function renderWalletButton() {
    const btn = $("#btn-connect");
    btn.textContent = account ? shortAddr(account) : "Connect Wallet";
    btn.title = account || "";
  }

  async function refreshVault(silent) {
    if (!vaultRO) return;
    try {
      if (!stableTok) stableTok = new ethers.Contract(await vaultRO.paymentToken(), ABI_S, readProvider);

      const s = await vaultRO.series(SERIES_ID);
      const now = Math.floor(Date.now() / 1000);
      $("#cert-name").textContent = s.name;
      $("#cert-asset").textContent = s.underlyingAsset;
      $("#cert-face").textContent = fmtUnits(s.faceValue) + " AED-S";
      $("#cert-total").textContent = s.issuedCertificates.toString() + " / " + s.totalCertificates.toString();
      $("#cert-profit").textContent = (Number(s.indicativeProfitBps) / 100).toFixed(1) + "% p.a. (indicative)";
      const matured = now >= Number(s.maturity);
      $("#cert-maturity").textContent = fmtDate(s.maturity) + (matured ? " · matured" : "");
      $("#cert-status").textContent = s.frozen ? "FROZEN" : matured ? (s.assetSold ? "REDEEMING" : "MATURED") : "OPEN";

      const [pending, pool, reserve, redPool, income, distributed] = await Promise.all([
        vaultRO.pendingApproval(SERIES_ID),
        vaultRO.distributablePool(SERIES_ID),
        vaultRO.profitReserve(SERIES_ID),
        vaultRO.redemptionPool(SERIES_ID),
        vaultRO.totalIncomeRecorded(SERIES_ID),
        vaultRO.totalDistributed(SERIES_ID),
      ]);
      $("#dist-pending").textContent = fmtUnits(pending) + " AED-S";
      $("#dist-pool").textContent = fmtUnits(pool) + " AED-S";
      $("#dist-reserve").textContent = fmtUnits(reserve) + " AED-S · " + (Number(await vaultRO.reserveBps()) / 100).toFixed(1) + "%";
      let epochs = 0;
      try { while (true) { await vaultRO.epochs(SERIES_ID, epochs); epochs++; } } catch {}
      $("#dist-epochs").textContent = String(epochs);

      if (account) {
        const [certs, redeemed, claimable] = await Promise.all([
          vaultRO.certificates(SERIES_ID, account),
          vaultRO.redeemed(SERIES_ID, account),
          vaultRO.claimable(SERIES_ID, account),
        ]);
        $("#inv-certs").textContent = certs.toString() + " certs";
        $("#inv-redeemed").textContent = fmtUnits(redeemed) + " AED-S";
        $("#dist-claimable").textContent = fmtUnits(claimable) + " AED-S";
      } else {
        $("#inv-certs").textContent = "—";
        $("#dist-claimable").textContent = "—";
      }
    } catch (err) {
      console.warn("vault:", err);
      const fallbacks = chainCfg(chainId ?? chainIdPref).rpcFallbacks || [];
      if (rpcFailures < fallbacks.length) {
        rpcFailures++;
        rebuildReadProvider();
        await refreshVault(silent);
        return;
      }
      rpcFailures = 0;
      rebuildReadProvider();
      if (!silent) toast("Could not read the vault — " + (err.shortMessage || err.message || ""), "error", 9000);
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
      vaultAddress = ethers.getAddress(addr);
      localStorage.setItem(LS_ADDRESS, vaultAddress);
      location.reload();
    });

    $("#btn-purchase").addEventListener("click", async () => {
      try {
        await requireSigner();
        const n = $("#purchase-amount").value;
        if (!n || Number(n) <= 0) return toast("Certificates must be ≥ 1", "error");
        const amount = BigInt(Math.floor(Number(n)));
        const cost = amount * (await vaultRO.series(SERIES_ID)).faceValue;
        const allowance = await stableTok.allowance(account, vaultAddress);
        if (allowance < cost) {
          const ap = await stableTok.connect(signer).approve(vaultAddress, cost);
          toast("⏳ Approve submitted — " + txLink(ap.hash), "info", 12000);
          await ap.wait();
        }
        await send(vaultRW.purchase(SERIES_ID, amount), "Certificates purchased");
        $("#purchase-amount").value = "";
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-redeem").addEventListener("click", async () => {
      try {
        await requireSigner();
        const n = $("#redeem-amount").value;
        if (!n || Number(n) <= 0) return toast("Certificates must be ≥ 1", "error");
        await send(vaultRW.redeem(SERIES_ID, BigInt(Math.floor(Number(n)))), "Redeemed");
        $("#redeem-amount").value = "";
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-distribute").addEventListener("click", async () => {
      try {
        await requireSigner();
        await send(vaultRW.distribute(SERIES_ID), "Epoch distributed");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-claim").addEventListener("click", async () => {
      try {
        await requireSigner();
        await send(vaultRW.claim(SERIES_ID), "Profit claimed");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-income").addEventListener("click", async () => {
      try {
        await requireSigner();
        const amt = $("#income-amount").value;
        if (!amt || Number(amt) <= 0) return toast("Amount must be > 0", "error");
        const amount = ethers.parseEther(amt);
        const allowance = await stableTok.allowance(account, vaultAddress);
        if (allowance < amount) {
          const ap = await stableTok.connect(signer).approve(vaultAddress, amount);
          toast("⏳ Approve submitted — " + txLink(ap.hash), "info", 12000);
          await ap.wait();
        }
        await send(vaultRW.recordIncome(SERIES_ID, amount), "Income recorded (pending Shariah)");
        $("#income-amount").value = "";
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-approve").addEventListener("click", async () => {
      try {
        await requireSigner();
        await send(vaultRW.approveIncome(SERIES_ID), "Income approved");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-sell").addEventListener("click", async () => {
      try {
        await requireSigner();
        const amt = $("#sale-proceeds").value;
        if (!amt || Number(amt) <= 0) return toast("Proceeds must be > 0", "error");
        await send(vaultRW.sellUnderlying(SERIES_ID, ethers.parseEther(amt)), "Asset sold");
        $("#sale-proceeds").value = "";
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    setInterval(() => { if (vaultRO) refreshVault(); }, 30000);
  }

  async function requireSigner() {
    if (!vaultRO || !vaultAddress) {
      const e = new Error("no vault"); e.__handled = true;
      toast("Configure the vault address first (Settings or the banner above)", "error");
      throw e;
    }
    if (!signer) {
      const e = new Error("no signer"); e.__handled = true;
      toast("Connect your wallet first", "error");
      throw e;
    }
    if (!vaultRW) vaultRW = new ethers.Contract(vaultAddress, ABI_V, signer);
  }

  async function send(txPromise, label) {
    const tx = await txPromise;
    toast("⏳ " + label + " submitted — " + txLink(tx.hash), "info", 12000);
    await tx.wait();
    toast("✅ " + label + " confirmed — " + txLink(tx.hash), "success", 9000);
    await refreshAll();
  }

  function saveSettings() {
    const addr = $("#set-vault-address").value.trim();
    if (addr && !ethers.isAddress(addr)) return toast("Invalid vault address", "error");
    if (addr) {
      vaultAddress = ethers.getAddress(addr);
      localStorage.setItem(LS_ADDRESS, vaultAddress);
    } else localStorage.removeItem(LS_ADDRESS);
    localStorage.setItem(LS_CHAIN, $("#set-chain").value);
    location.reload();
  }

  document.addEventListener("DOMContentLoaded", init);
})();
