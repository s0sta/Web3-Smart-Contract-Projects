/* ============================================================
   Tamweel dApp — application logic
   ethers.js v6 (UMD global), no build step.
   ============================================================ */

"use strict";

(function () {
  const $ = (s) => document.querySelector(s);
  const cfg = window.APP_CONFIG || {};
  const ABI_VLT = window.TAMWEELVAULT_ABI || [];
  const ABI_CMP = window.TAMWEELCOMPLIANCE_ABI || [];
  const ABI_ORC = window.TAMWEELORACLE_ABI || [];
  const ABI_RTM = window.TAMWEELRATEMODEL_ABI || [];
  const ABI_MKT = window.TAMWEELMARKETS_ABI || [];
  const ABI_LNS = window.TAMWEELLOANS_ABI || [];
  const ABI_GOV = window.TAMWEELGOVERNOR_ABI || [];
  const ABI_STB = window.TAMWEEL_STABLE_ABI || [];

  const LS_ADDRESS = "tamweel.vaultAddress";
  const LS_CHAIN = "tamweel.chainId";

  const GOV_STATES = ["Review", "Voting", "Timelock", "Succeeded", "Executed", "Defeated", "Canceled"];

  /* ---------------- state ---------------- */
  let ifaceGov = null;
  let vaultAddress = localStorage.getItem(LS_ADDRESS) || cfg.vaultAddress || "";
  let chainIdPref = Number(localStorage.getItem(LS_CHAIN) || cfg.defaultChainId);
  let readProvider = null;
  let walletProvider = null;
  let signer = null;
  let account = null;
  let RO = {};
  let RW = {};
  let chainId = null;
  let rpcFailures = 0;

  const marketId = cfg.marketId || 0;

  /* ---------------- helpers ---------------- */

  function chainCfg(id) {
    return cfg.chains[id] || { name: "Unknown network", short: "unknown", rpc: null, explorer: null, currency: "ETH" };
  }
  function rpcFor(id) { return chainCfg(id).rpc || "https://ethereum-rpc.publicnode.com"; }
  function fallbackRpc(id) { return (chainCfg(id).rpcFallbacks || [])[rpcFailures % (chainCfg(id).rpcFallbacks?.length || 1)]; }
  function rebuildReadProvider() {
    const rpc = rpcFailures > 0 ? fallbackRpc(chainId ?? chainIdPref) : rpcFor(chainId ?? chainIdPref);
    readProvider = new ethers.JsonRpcProvider(rpc);
    RO.vault = new ethers.Contract(vaultAddress, ABI_VLT, readProvider);
    RO.compliance = new ethers.Contract(cfg.complianceAddress, ABI_CMP, readProvider);
    RO.oracle = new ethers.Contract(cfg.oracleAddress, ABI_ORC, readProvider);
    RO.rateModel = new ethers.Contract(cfg.rateModelAddress, ABI_RTM, readProvider);
    RO.markets = new ethers.Contract(cfg.marketsAddress, ABI_MKT, readProvider);
    RO.loans = new ethers.Contract(cfg.loansAddress, ABI_LNS, readProvider);
    RO.governor = new ethers.Contract(cfg.governorAddress, ABI_GOV, readProvider);
    RO.stable = new ethers.Contract(cfg.stableAddress, ABI_STB, readProvider);
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
    if (err.data && ifaceGov) {
      try { const e = ifaceGov.parseError(err.data); if (e) return e.name; } catch {}
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
    ifaceGov = new ethers.Interface(ABI_GOV);

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
      rebuildReadProvider();
    } else RO.vault = null;

    $("#setup-banner").hidden = !!RO.vault;
    $("#chain-badge").textContent = chainCfg(chainIdPref).name;
    $("#chain-badge").classList.toggle("ok", !!chainCfg(chainIdPref).rpc);
    $("#footer-address").textContent = RO.vault ? shortAddr(vaultAddress) : "not configured";
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
      account = null; signer = null; RW = {};
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
    await refreshBank();
  }

  function renderWalletButton() {
    const btn = $("#btn-connect");
    btn.textContent = account ? shortAddr(account) : "Connect Wallet";
    btn.title = account || "";
  }

  async function refreshBank(silent) {
    if (!RO.vault) return;
    try {
      const [assets, borrowed, totalDebt] = await Promise.all([
        RO.vault.totalAssets(),
        RO.vault.borrowedAssets(),
        RO.markets.totalDebt(),
      ]);
      const utilBps = assets > 0n ? (totalDebt * 10000n) / assets : 0n;
      const borrowRate = await RO.rateModel.borrowRatePerSecond(utilBps);
      const apr = borrowRate * 365n * 86400n / 10n ** 18n;

      $("#strip-assets").textContent = fmtUnits(assets) + " AED-S";
      $("#strip-borrowed").textContent = fmtUnits(borrowed) + " AED-S";
      $("#strip-util").textContent = (Number(utilBps) / 100).toFixed(1) + "%";
      $("#strip-rate").textContent = (Number(apr) / 1e16).toFixed(2) + "% APR";

      if (account) {
        const [myShares, redeem] = await Promise.all([
          RO.vault.balanceOf(account),
          RO.vault.previewRedeem(await RO.vault.balanceOf(account)),
        ]);
        $("#strip-shares").textContent = fmtUnits(myShares);
        $("#dep-shares").textContent = fmtUnits(myShares) + " shares";
        $("#dep-value").textContent = fmtUnits(redeem) + " AED-S";

        const [coll, debt, health, profile] = await Promise.all([
          RO.markets.collateral(marketId, account),
          RO.markets.debtOf(marketId, account),
          RO.markets.healthFactor(marketId, account),
          RO.compliance.profiles(account),
        ]);
        $("#cr-collateral").textContent = fmtUnits(coll) + " ETH";
        $("#cr-debt").textContent = fmtUnits(debt) + " AED-S";
        $("#cr-health").textContent = health === ethers.MaxUint256 ? "∞" : fmtUnits(health).short;
        $("#cr-score").textContent = String(profile.creditScore);
      } else {
        $("#strip-shares").textContent = "—";
        $("#dep-shares").textContent = "—";
        $("#cr-collateral").textContent = "—";
      }

      // governance proposals
      let rows = "";
      let n = 0;
      try { while (true) { await RO.governor.proposals(n); n++; } } catch {}
      for (let i = n - 1; i >= 0 && i >= n - 8; i--) {
        const p = await RO.governor.proposals(i);
        const st = Number(await RO.governor.state(i));
        rows +=
          '<div class="item-row"><span class="mono">#' + i + "</span>" +
          '<span class="muted small">' + (p.description || "") + "</span>" +
          '<span class="item-right">' + GOV_STATES[st] + "</span>" +
          (st === 1 ? '<div class="item-actions"><button class="btn btn-ghost btn-sm" data-action="vote-for" data-id="' + i + '">For</button><button class="btn btn-ghost btn-sm" data-action="vote-against" data-id="' + i + '">Against</button></div>' : "") +
          (st === 3 ? '<div class="item-actions"><button class="btn btn-primary btn-sm" data-action="execute" data-id="' + i + '">Execute</button></div>' : "") +
          "</div>";
      }
      $("#gov-list").innerHTML = rows || '<p class="muted">no proposals yet</p>';
    } catch (err) {
      console.warn("bank:", err);
      const fallbacks = chainCfg(chainId ?? chainIdPref).rpcFallbacks || [];
      if (rpcFailures < fallbacks.length) {
        rpcFailures++;
        rebuildReadProvider();
        await refreshBank(silent);
        return;
      }
      rpcFailures = 0;
      rebuildReadProvider();
      if (!silent) toast("Could not read the bank — " + (err.shortMessage || err.message || ""), "error", 9000);
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

    $("#btn-deposit").addEventListener("click", async () => {
      try {
        await requireSigner();
        const amt = $("#deposit-amount").value;
        if (!amt || Number(amt) <= 0) return toast("Amount must be > 0", "error");
        const amount = ethers.parseEther(amt);
        const allowance = await RO.stable.allowance(account, vaultAddress);
        if (allowance < amount) {
          const ap = await RO.stable.connect(signer).approve(vaultAddress, amount * 2n);
          toast("⏳ Approve submitted — " + txLink(ap.hash), "info", 12000);
          await ap.wait();
        }
        await send(RW.vault.deposit(amount), "Deposited");
        $("#deposit-amount").value = "";
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-withdraw").addEventListener("click", async () => {
      try {
        await requireSigner();
        const amt = $("#withdraw-amount").value;
        if (!amt || Number(amt) <= 0) return toast("Shares must be > 0", "error");
        await send(RW.vault.withdraw(ethers.parseEther(amt)), "Withdrawn");
        $("#withdraw-amount").value = "";
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-supply").addEventListener("click", async () => {
      try {
        await requireSigner();
        const amt = $("#supply-amount").value;
        if (!amt || Number(amt) <= 0) return toast("Amount must be > 0", "error");
        const amount = ethers.parseEther(amt);
        const allowance = await RO.stable.allowance(account, cfg.marketsAddress);
        if (allowance < amount) {
          const ap = await RO.stable.connect(signer).approve(cfg.marketsAddress, amount * 2n);
          toast("⏳ Approve submitted — " + txLink(ap.hash), "info", 12000);
          await ap.wait();
        }
        await send(RW.markets.supply(marketId, amount), "Collateral supplied");
        $("#supply-amount").value = "";
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-borrow").addEventListener("click", async () => {
      try {
        await requireSigner();
        const amt = $("#borrow-amount").value;
        if (!amt || Number(amt) <= 0) return toast("Amount must be > 0", "error");
        await send(RW.markets.borrow(marketId, ethers.parseEther(amt)), "Borrowed");
        $("#borrow-amount").value = "";
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-repay").addEventListener("click", async () => {
      try {
        await requireSigner();
        const amt = $("#repay-amount").value;
        if (!amt || Number(amt) <= 0) return toast("Amount must be > 0", "error");
        const amount = ethers.parseEther(amt);
        const allowance = await RO.stable.allowance(account, vaultAddress);
        if (allowance < amount) {
          const ap = await RO.stable.connect(signer).approve(vaultAddress, amount * 2n);
          toast("⏳ Approve submitted — " + txLink(ap.hash), "info", 12000);
          await ap.wait();
        }
        await send(RW.markets.repay(marketId, amount), "Repaid");
        $("#repay-amount").value = "";
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-loan").addEventListener("click", async () => {
      try {
        await requireSigner();
        const principal = $("#loan-principal").value;
        const installments = $("#loan-installments").value;
        if (!principal || Number(principal) <= 0) return toast("Principal must be > 0", "error");
        if (!installments || Number(installments) < 1) return toast("Installments must be ≥ 1", "error");
        await send(RW.loans.requestLoan(ethers.parseEther(principal), BigInt(installments), 30n * 86400n, "business financing"), "Loan requested");
        $("#loan-principal").value = ""; $("#loan-installments").value = "";
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-propose").addEventListener("click", async () => {
      try {
        await requireSigner();
        const bps = $("#gov-rate").value;
        if (bps === "" || Number(bps) < 0 || Number(bps) > 10000) return toast("Rate must be 0–10000 bps", "error");
        const calldata = RO.loans.interface.encodeFunctionData("setLoanInterestBps", [Number(bps)]);
        await send(RW.governor.propose(cfg.loansAddress, 0n, calldata, "Set loan interest to " + (Number(bps) / 100).toFixed(1) + "%"), "Proposal created");
        $("#gov-rate").value = "";
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#gov-list").addEventListener("click", async (e) => {
      const btn = e.target.closest("[data-action]");
      if (!btn) return;
      const id = BigInt(btn.dataset.id);
      try {
        await requireSigner();
        const action = btn.dataset.action;
        if (action === "vote-for") await send(RW.governor.vote(id, true), "Vote cast");
        else if (action === "vote-against") await send(RW.governor.vote(id, false), "Vote cast");
        else if (action === "execute") await send(RW.governor.execute(id), "Proposal executed");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    setInterval(() => { if (RO.vault) refreshBank(); }, 30000);
  }

  async function requireSigner() {
    if (!RO.vault || !vaultAddress) {
      const e = new Error("no vault"); e.__handled = true;
      toast("Configure the vault address first (Settings or the banner above)", "error");
      throw e;
    }
    if (!signer) {
      const e = new Error("no signer"); e.__handled = true;
      toast("Connect your wallet first", "error");
      throw e;
    }
    RW.vault = new ethers.Contract(vaultAddress, ABI_VLT, signer);
    RW.markets = new ethers.Contract(cfg.marketsAddress, ABI_MKT, signer);
    RW.loans = new ethers.Contract(cfg.loansAddress, ABI_LNS, signer);
    RW.governor = new ethers.Contract(cfg.governorAddress, ABI_GOV, signer);
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
