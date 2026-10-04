/* ============================================================
   Estate Tokenization dApp — application logic
   ethers.js v6 (UMD global), no build step.
   ============================================================ */

"use strict";

(function () {
  const $ = (s) => document.querySelector(s);
  const cfg = window.APP_CONFIG || {};
  const ABI_R = window.ESTATE_REGISTRY_ABI || [];
  const ABI_D = window.ESTATE_DISTRIBUTOR_ABI || [];
  const ABI_S = window.ESTATE_STABLE_ABI || [];

  const LS_ADDRESS = "estate.registryAddress";
  const LS_CHAIN = "estate.chainId";

  /* ---------------- state ---------------- */
  let ifaceR = null;
  let registryAddress = localStorage.getItem(LS_ADDRESS) || cfg.registryAddress || "";
  let chainIdPref = Number(localStorage.getItem(LS_CHAIN) || cfg.defaultChainId);
  let readProvider = null;
  let walletProvider = null;
  let signer = null;
  let account = null;
  let registryRO = null;
  let registryRW = null;
  let distributorRO = null;
  let distributorRW = null;
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
    registryRO = new ethers.Contract(registryAddress, ABI_R, readProvider);
    distributorRO = null; stableTok = null;
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
  function fmtUsd(bn) { return "$" + fmtUnits(bn); }
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
    if (err.data && ifaceR) {
      try { const e = ifaceR.parseError(err.data); if (e) return e.name; } catch {}
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
    ifaceR = new ethers.Interface(ABI_R);

    try {
      const res = await fetch("api/config.php", { cache: "no-store" });
      if (res.ok) {
        const data = await res.json();
        if (data && data.registryAddress && !localStorage.getItem(LS_ADDRESS)) registryAddress = data.registryAddress;
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
    registryAddress = localStorage.getItem(LS_ADDRESS) || registryAddress || "";

    readProvider = new ethers.JsonRpcProvider(rpcFor(chainIdPref));
    chainId = chainIdPref;

    if (registryAddress && ethers.isAddress(registryAddress)) {
      registryRO = new ethers.Contract(registryAddress, ABI_R, readProvider);
    } else registryRO = null;
    registryRW = null; distributorRO = null; distributorRW = null;

    $("#setup-banner").hidden = !!registryRO;
    $("#chain-badge").textContent = chainCfg(chainIdPref).name;
    $("#chain-badge").classList.toggle("ok", !!chainCfg(chainIdPref).rpc);
    $("#footer-address").textContent = registryRO ? shortAddr(registryAddress) : "not configured";
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
      account = null; signer = null; registryRW = null; distributorRW = null;
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
    await refreshEstate();
  }

  function renderWalletButton() {
    const btn = $("#btn-connect");
    btn.textContent = account ? shortAddr(account) : "Connect Wallet";
    btn.title = account || "";
  }

  async function refreshEstate(silent) {
    if (!registryRO) return;
    try {
      if (!distributorRO) {
        // the distributor is the canonical yield contract; resolve it from its own deployment
        // (address saved in config on deployment — fallback: derive from event-free static call)
        distributorRO = new ethers.Contract(cfg.distributorAddress, ABI_D, readProvider);
        stableTok = new ethers.Contract(cfg.stableAddress, ABI_S, readProvider);
      }
      if (!cfg.distributorAddress) return;

      const p = await registryRO.properties(0);
      $("#prop-name").textContent = p.name || "Marina Gate Tower";
      $("#prop-valuation").textContent = fmtUsd(p.valuationUsd);
      $("#prop-shares").textContent = fmtUnits(p.totalShares);
      $("#prop-issued").textContent = fmtUnits(p.issuedShares) + " / " + fmtUnits(p.totalShares);
      $("#prop-status").innerHTML = p.frozen
        ? '<span class="status-pill status-frozen">FROZEN</span>'
        : '<span class="status-pill status-ok">ACTIVE</span>';

      const [rcvd, pending, fund, reserve] = await Promise.all([
        distributorRO.totalRentReceived(0),
        distributorRO.pendingPool(0),
        distributorRO.maintenanceFund(0),
        distributorRO.maintenanceReserveBps(),
      ]);
      let epochCount = 0;
      try { while (true) { await distributorRO.epochs(0, epochCount); epochCount++; } } catch {}
      $("#dist-received").textContent = fmtUnits(rcvd) + " AED-S";
      $("#dist-pending").textContent = fmtUnits(pending) + " AED-S";
      $("#dist-epochs").textContent = String(epochCount);
      $("#dist-fund").textContent = fmtUnits(fund) + " AED-S · " + (Number(reserve) / 100).toFixed(1) + "% reserve";
      $("#compliance-box").hidden = false;

      if (account) {
        const [mine, kyc, claimable, isManager, isCompliance] = await Promise.all([
          registryRO.balanceOf(0, account),
          registryRO.whitelisted(0, account),
          distributorRO.claimable(0, account),
          registryRO.hasRole(registryRO.MANAGER_ROLE(), account),
          registryRO.hasRole(registryRO.COMPLIANCE_ROLE(), account),
        ]);
        $("#prop-mine").textContent = fmtUnits(mine);
        $("#prop-kyc").innerHTML = kyc
          ? '<span class="status-pill status-ok">KYC PASSED</span>'
          : '<span class="status-pill status-frozen">NOT WHITELISTED</span>';
        $("#dist-claimable").textContent = fmtUnits(claimable) + " AED-S";
        $("#btn-distribute").hidden = !(isManager || isCompliance);
        $("#compliance-box").hidden = !isCompliance;
      } else {
        $("#prop-mine").textContent = "—";
        $("#prop-kyc").textContent = "—";
        $("#dist-claimable").textContent = "—";
      }
    } catch (err) {
      console.warn("estate:", err);
      const fallbacks = chainCfg(chainId ?? chainIdPref).rpcFallbacks || [];
      if (rpcFailures < fallbacks.length) {
        rpcFailures++;
        rebuildReadProvider();
        await refreshEstate(silent);
        return;
      }
      rpcFailures = 0;
      rebuildReadProvider();
      if (!silent) toast("Could not read the estate — " + (err.shortMessage || err.message || ""), "error", 9000);
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
      registryAddress = ethers.getAddress(addr);
      localStorage.setItem(LS_ADDRESS, registryAddress);
      location.reload();
    });

    $("#btn-transfer").addEventListener("click", async () => {
      try {
        await requireSigner();
        const to = $("#transfer-to").value.trim();
        const amt = $("#transfer-amount").value;
        if (!ethers.isAddress(to)) return toast("Invalid recipient address", "error");
        if (!amt || Number(amt) <= 0) return toast("Amount must be > 0", "error");
        await send(registryRW.transferShares(0, ethers.getAddress(to), ethers.parseEther(amt)), "Shares transferred");
        $("#transfer-to").value = ""; $("#transfer-amount").value = "";
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-pay-rent").addEventListener("click", async () => {
      try {
        await requireSigner();
        const amt = $("#rent-amount").value;
        if (!amt || Number(amt) <= 0) return toast("Amount must be > 0", "error");
        const amount = ethers.parseEther(amt);
        const distAddr = await distributorRW.getAddress();
        const allowance = await stableTok.allowance(account, distAddr);
        if (allowance < amount) {
          const ap = await stableTok.connect(signer).approve(distAddr, amount);
          toast("⏳ Approve submitted — " + txLink(ap.hash), "info", 12000);
          await ap.wait();
        }
        await send(distributorRW.payRent(0, amount), "Rent paid");
        $("#rent-amount").value = "";
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-distribute").addEventListener("click", async () => {
      try {
        await requireSigner();
        await send(distributorRW.distribute(0), "Epoch distributed");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-claim").addEventListener("click", async () => {
      try {
        await requireSigner();
        await send(distributorRW.claim(0), "Yield claimed");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-appraise").addEventListener("click", async () => {
      try {
        await requireSigner();
        const v = $("#appraise-value").value;
        if (!v || Number(v) <= 0) return toast("Valuation must be > 0", "error");
        await send(registryRW.appraise(0, ethers.parseEther(v)), "Appraisal filed");
        $("#appraise-value").value = "";
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-maint").addEventListener("click", async () => {
      try {
        await requireSigner();
        const to = $("#maint-to").value.trim();
        const amt = $("#maint-amount").value;
        if (!ethers.isAddress(to)) return toast("Invalid vendor address", "error");
        if (!amt || Number(amt) <= 0) return toast("Amount must be > 0", "error");
        await send(distributorRW.spendMaintenance(0, ethers.getAddress(to), ethers.parseEther(amt)), "Maintenance paid");
        $("#maint-to").value = ""; $("#maint-amount").value = "";
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-kyc-add").addEventListener("click", () => kycAction(true));
    $("#btn-kyc-remove").addEventListener("click", () => kycAction(false));
    $("#btn-freeze").addEventListener("click", async () => {
      try {
        await requireSigner();
        const p = await registryRO.properties(0);
        await send(registryRW.setFrozen(0, !p.frozen), p.frozen ? "Unfrozen" : "Property frozen");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-reserve").addEventListener("click", async () => {
      try {
        await requireSigner();
        const bps = $("#reserve-bps").value;
        if (bps === "" || Number(bps) < 0 || Number(bps) > 10000) return toast("Reserve must be 0–10000 bps", "error");
        await send(distributorRW.setMaintenanceReserveBps(Number(bps)), "Reserve updated");
        $("#reserve-bps").value = "";
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    setInterval(() => { if (registryRO) refreshEstate(); }, 30000);
  }

  async function kycAction(allowed) {
    try {
      await requireSigner();
      const addr = $("#kyc-address").value.trim();
      if (!ethers.isAddress(addr)) return toast("Invalid address", "error");
      await send(registryRW.setWhitelisted(0, ethers.getAddress(addr), allowed), allowed ? "Whitelisted" : "Revoked");
      $("#kyc-address").value = "";
    } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
  }

  async function requireSigner() {
    if (!registryRO || !registryAddress) {
      const e = new Error("no registry"); e.__handled = true;
      toast("Configure the registry address first (Settings or the banner above)", "error");
      throw e;
    }
    if (!signer) {
      const e = new Error("no signer"); e.__handled = true;
      toast("Connect your wallet first", "error");
      throw e;
    }
    if (!registryRW) registryRW = new ethers.Contract(registryAddress, ABI_R, signer);
    if (!distributorRW) distributorRW = new ethers.Contract(cfg.distributorAddress, ABI_D, signer);
  }

  async function send(txPromise, label) {
    const tx = await txPromise;
    toast("⏳ " + label + " submitted — " + txLink(tx.hash), "info", 12000);
    await tx.wait();
    toast("✅ " + label + " confirmed — " + txLink(tx.hash), "success", 9000);
    await refreshAll();
  }

  function saveSettings() {
    const addr = $("#set-registry-address").value.trim();
    if (addr && !ethers.isAddress(addr)) return toast("Invalid registry address", "error");
    if (addr) {
      registryAddress = ethers.getAddress(addr);
      localStorage.setItem(LS_ADDRESS, registryAddress);
    } else localStorage.removeItem(LS_ADDRESS);
    localStorage.setItem(LS_CHAIN, $("#set-chain").value);
    location.reload();
  }

  document.addEventListener("DOMContentLoaded", init);
})();
