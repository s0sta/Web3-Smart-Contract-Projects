/* ============================================================
   VARA Treasury dApp — application logic
   ethers.js v6 (UMD global), no build step.
   ============================================================ */

"use strict";

(function () {
  const $ = (s) => document.querySelector(s);
  const cfg = window.APP_CONFIG || {};
  const ABI_T = window.VARA_TREASURY_ABI || [];
  const ABI_C = window.VARA_COMPLIANCE_ABI || [];
  const ABI_S = window.VARA_STABLE_ABI || [];

  const LS_ADDRESS = "vara.treasuryAddress";
  const LS_CHAIN = "vara.chainId";

  /* ---------------- state ---------------- */
  let ifaceT = null;
  let treasuryAddress = localStorage.getItem(LS_ADDRESS) || cfg.treasuryAddress || "";
  let chainIdPref = Number(localStorage.getItem(LS_CHAIN) || cfg.defaultChainId);
  let readProvider = null;
  let walletProvider = null;
  let signer = null;
  let account = null;
  let treasuryRO = null;
  let treasuryRW = null;
  let complianceRO = null;
  let complianceRW = null;
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
    treasuryRO = new ethers.Contract(treasuryAddress, ABI_T, readProvider);
    complianceRO = null; stableTok = null;
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
    if (err.data && ifaceT) {
      try { const e = ifaceT.parseError(err.data); if (e) return e.name; } catch {}
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
    ifaceT = new ethers.Interface(ABI_T);

    try {
      const res = await fetch("api/config.php", { cache: "no-store" });
      if (res.ok) {
        const data = await res.json();
        if (data && data.treasuryAddress && !localStorage.getItem(LS_ADDRESS)) treasuryAddress = data.treasuryAddress;
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
    treasuryAddress = localStorage.getItem(LS_ADDRESS) || treasuryAddress || "";

    readProvider = new ethers.JsonRpcProvider(rpcFor(chainIdPref));
    chainId = chainIdPref;

    if (treasuryAddress && ethers.isAddress(treasuryAddress)) {
      treasuryRO = new ethers.Contract(treasuryAddress, ABI_T, readProvider);
    } else treasuryRO = null;
    treasuryRW = null; complianceRO = null;

    $("#setup-banner").hidden = !!treasuryRO;
    $("#chain-badge").textContent = chainCfg(chainIdPref).name;
    $("#chain-badge").classList.toggle("ok", !!chainCfg(chainIdPref).rpc);
    $("#footer-address").textContent = treasuryRO ? shortAddr(treasuryAddress) : "not configured";
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
      account = null; signer = null; treasuryRW = null; complianceRW = null;
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
    await refreshTreasury();
  }

  function renderWalletButton() {
    const btn = $("#btn-connect");
    btn.textContent = account ? shortAddr(account) : "Connect Wallet";
    btn.title = account || "";
  }

  async function refreshTreasury(silent) {
    if (!treasuryRO) return;
    try {
      if (!complianceRO) complianceRO = new ethers.Contract(await treasuryRO.compliance(), ABI_C, readProvider);
      if (!stableTok) stableTok = new ethers.Contract(cfg.stableAddress, ABI_S, readProvider);

      const [paused, liabilities, house, reserve, recovery] = await Promise.all([
        treasuryRO.paused(),
        treasuryRO.clientTotals(cfg.stableAddress),
        treasuryRO.houseBalances(cfg.stableAddress),
        treasuryRO.reserveBps(),
        treasuryRO.recoveryAddress(),
      ]);
      $("#strip-status").innerHTML = paused
        ? '<span class="status-pill status-frozen">PAUSED</span>'
        : '<span class="status-pill status-ok">OPERATIONAL</span>';
      $("#strip-liabilities").textContent = fmtUnits(liabilities) + " AED-S";
      $("#strip-house").textContent = fmtUnits(house) + " AED-S";
      $("#strip-reserve").textContent = (Number(reserve) / 100).toFixed(1) + "% · recovery " + shortAddr(recovery);

      if (account) {
        const [bal, ethBal, used] = await Promise.all([
          treasuryRO.clientBalances(cfg.stableAddress, account),
          treasuryRO.ethClientBalances(account),
          treasuryRO.dailyWithdrawn(account, cfg.stableAddress),
        ]);
        $("#acct-balance").textContent = fmtUnits(bal) + " AED-S";
        $("#acct-eth").textContent = fmtUnits(ethBal) + " ETH";
        const tier = Number((await complianceRO.accounts(account)).tier);
        $("#acct-tier").textContent = ["None", "Standard", "Enhanced"][tier];
        $("#acct-daily").textContent = fmtUnits(await complianceRO.dailyLimitFor(account)) + " AED-S";
        $("#acct-used").textContent = fmtUnits(used) + " AED-S";

        const roles = [];
        if (await treasuryRO.hasRole(treasuryRO.COMPLIANCE_ROLE(), account)) roles.push("compliance");
        if (await treasuryRO.hasRole(treasuryRO.GUARDIAN_ROLE(), account)) roles.push("guardian");
        if (await treasuryRO.hasRole(treasuryRO.OPERATOR_ROLE(), account)) roles.push("operator");
        $("#strip-role").textContent = roles.length ? roles.join(" · ") : "client";
      } else {
        $("#acct-balance").textContent = "—";
        $("#strip-role").textContent = "—";
      }
    } catch (err) {
      console.warn("treasury:", err);
      const fallbacks = chainCfg(chainId ?? chainIdPref).rpcFallbacks || [];
      if (rpcFailures < fallbacks.length) {
        rpcFailures++;
        rebuildReadProvider();
        await refreshTreasury(silent);
        return;
      }
      rpcFailures = 0;
      rebuildReadProvider();
      if (!silent) toast("Could not read the treasury — " + (err.shortMessage || err.message || ""), "error", 9000);
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
      treasuryAddress = ethers.getAddress(addr);
      localStorage.setItem(LS_ADDRESS, treasuryAddress);
      location.reload();
    });

    $("#btn-deposit").addEventListener("click", async () => {
      try {
        await requireSigner();
        const amt = $("#deposit-amount").value;
        if (!amt || Number(amt) <= 0) return toast("Amount must be > 0", "error");
        const amount = ethers.parseEther(amt);
        const allowance = await stableTok.allowance(account, treasuryAddress);
        if (allowance < amount) {
          const ap = await stableTok.connect(signer).approve(treasuryAddress, amount);
          toast("⏳ Approve submitted — " + txLink(ap.hash), "info", 12000);
          await ap.wait();
        }
        await send(treasuryRW.deposit(cfg.stableAddress, amount), "Deposited");
        $("#deposit-amount").value = "";
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-deposit-eth").addEventListener("click", async () => {
      try {
        await requireSigner();
        const amt = $("#eth-amount").value;
        if (!amt || Number(amt) <= 0) return toast("Amount must be > 0", "error");
        await send(treasuryRW.depositEth({ value: ethers.parseEther(amt) }), "ETH deposited");
        $("#eth-amount").value = "";
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-withdraw").addEventListener("click", async () => {
      try {
        await requireSigner();
        const to = $("#withdraw-to").value.trim();
        const amt = $("#withdraw-amount").value;
        if (!ethers.isAddress(to)) return toast("Invalid destination address", "error");
        if (!amt || Number(amt) <= 0) return toast("Amount must be > 0", "error");
        await send(treasuryRW.withdraw(cfg.stableAddress, ethers.getAddress(to), ethers.parseEther(amt)), "Withdrawn");
        $("#withdraw-to").value = ""; $("#withdraw-amount").value = "";
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-kyc").addEventListener("click", async () => {
      try {
        await requireSigner();
        const addr = $("#kyc-address").value.trim();
        if (!ethers.isAddress(addr)) return toast("Invalid address", "error");
        await send(complianceRW.setKyc(ethers.getAddress(addr), $("#kyc-tier").value), "KYC set");
        $("#kyc-address").value = "";
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-sanction").addEventListener("click", () => screenAction(true));
    $("#btn-unsanction").addEventListener("click", () => screenAction(false));

    $("#btn-freeze").addEventListener("click", async () => {
      try {
        await requireSigner();
        const addr = $("#freeze-address").value.trim();
        if (!ethers.isAddress(addr)) return toast("Invalid address", "error");
        await send(treasuryRW.freezeAccount(ethers.getAddress(addr)), "Account frozen");
        $("#freeze-address").value = "";
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-forced").addEventListener("click", async () => {
      try {
        await requireSigner();
        const addr = $("#freeze-address").value.trim();
        if (!ethers.isAddress(addr)) return toast("Invalid address", "error");
        const bal = await treasuryRO.clientBalances(cfg.stableAddress, addr);
        const half = bal / 2n;
        if (half === 0n) return toast("That account holds nothing to transfer", "error");
        await send(treasuryRW.forcedTransfer(ethers.getAddress(addr), cfg.stableAddress, half), "Forced transfer");
        $("#freeze-address").value = "";
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-cp").addEventListener("click", async () => {
      try {
        await requireSigner();
        const addr = $("#cp-address").value.trim();
        if (!ethers.isAddress(addr)) return toast("Invalid address", "error");
        await send(complianceRW.setCounterparty(ethers.getAddress(addr), true), "Counterparty approved");
        $("#cp-address").value = "";
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-pause").addEventListener("click", async () => {
      try {
        await requireSigner();
        await send(treasuryRW.pause(), "Paused");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });
    $("#btn-unpause").addEventListener("click", async () => {
      try {
        await requireSigner();
        await send(treasuryRW.unpause(), "Unpaused");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });
    $("#btn-drain").addEventListener("click", async () => {
      try {
        await requireSigner();
        await send(treasuryRW.emergencyDrainAssets([cfg.stableAddress]), "Emergency drain");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });
    $("#btn-reserve").addEventListener("click", async () => {
      try {
        await requireSigner();
        const bps = $("#reserve-bps").value;
        if (bps === "" || Number(bps) < 0 || Number(bps) > 10000) return toast("Reserve must be 0–10000 bps", "error");
        await send(treasuryRW.setReserveBps(Number(bps)), "Reserve updated");
        $("#reserve-bps").value = "";
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });
    $("#btn-recovery").addEventListener("click", async () => {
      try {
        await requireSigner();
        const addr = $("#recovery-address").value.trim();
        if (!ethers.isAddress(addr)) return toast("Invalid address", "error");
        await send(treasuryRW.setRecoveryAddress(ethers.getAddress(addr)), "Recovery address set");
        $("#recovery-address").value = "";
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    setInterval(() => { if (treasuryRO) refreshTreasury(); }, 30000);
  }

  async function screenAction(sanctioned) {
    try {
      await requireSigner();
      const addr = $("#screen-address").value.trim();
      if (!ethers.isAddress(addr)) return toast("Invalid address", "error");
      await send(complianceRW.setSanctioned(ethers.getAddress(addr), sanctioned), sanctioned ? "Sanctioned" : "Cleared");
      $("#screen-address").value = "";
    } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
  }

  async function requireSigner() {
    if (!treasuryRO || !treasuryAddress) {
      const e = new Error("no treasury"); e.__handled = true;
      toast("Configure the treasury address first (Settings or the banner above)", "error");
      throw e;
    }
    if (!signer) {
      const e = new Error("no signer"); e.__handled = true;
      toast("Connect your wallet first", "error");
      throw e;
    }
    if (!treasuryRW) treasuryRW = new ethers.Contract(treasuryAddress, ABI_T, signer);
    if (!complianceRW) complianceRW = new ethers.Contract(cfg.complianceAddress, ABI_C, signer);
  }

  async function send(txPromise, label) {
    const tx = await txPromise;
    toast("⏳ " + label + " submitted — " + txLink(tx.hash), "info", 12000);
    await tx.wait();
    toast("✅ " + label + " confirmed — " + txLink(tx.hash), "success", 9000);
    await refreshAll();
  }

  function saveSettings() {
    const addr = $("#set-treasury-address").value.trim();
    if (addr && !ethers.isAddress(addr)) return toast("Invalid treasury address", "error");
    if (addr) {
      treasuryAddress = ethers.getAddress(addr);
      localStorage.setItem(LS_ADDRESS, treasuryAddress);
    } else localStorage.removeItem(LS_ADDRESS);
    localStorage.setItem(LS_CHAIN, $("#set-chain").value);
    location.reload();
  }

  document.addEventListener("DOMContentLoaded", init);
})();
