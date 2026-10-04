/* ============================================================
   Rahala dApp — application logic
   ethers.js v6 (UMD global), no build step.
   ============================================================ */

"use strict";

(function () {
  const $ = (s) => document.querySelector(s);
  const cfg = window.APP_CONFIG || {};
  const ABI_ACC = window.RAHALAACCOUNTS_ABI || [];
  const ABI_AED = window.RAHALASTABLE_ABI || [];
  const ABI_USD = window.RAHALA_USD_ABI || [];
  const ABI_ORC = window.RAHALAORACLE_ABI || [];
  const ABI_TRS = window.RAHALATREASURY_ABI || [];
  const ABI_FX = window.RAHALAFX_ABI || [];
  const ABI_ESC = window.RAHALAESCROW_ABI || [];
  const ABI_INV = window.RAHALAINVOICES_ABI || [];
  const ABI_NET = window.RAHALASETTLEMENT_ABI || [];
  const ABI_GOV = window.RAHALAGOVERNOR_ABI || [];

  const LS_ADDRESS = "rahala.accountsAddress";
  const LS_CHAIN = "rahala.chainId";

  const GOV_STATES = ["Review", "Voting", "Timelock", "Succeeded", "Executed", "Defeated", "Canceled"];

  /* ---------------- state ---------------- */
  let ifaceGov = null;
  let accountsAddress = localStorage.getItem(LS_ADDRESS) || cfg.accountsAddress || "";
  let chainIdPref = Number(localStorage.getItem(LS_CHAIN) || cfg.defaultChainId);
  let readProvider = null;
  let walletProvider = null;
  let signer = null;
  let account = null;
  let RO = {};
  let RW = {};
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
    RO.accounts = new ethers.Contract(accountsAddress, ABI_ACC, readProvider);
    RO.aeds = new ethers.Contract(cfg.aedsAddress, ABI_AED, readProvider);
    RO.usd = new ethers.Contract(cfg.usdAddress, ABI_USD, readProvider);
    RO.oracle = new ethers.Contract(cfg.oracleAddress, ABI_ORC, readProvider);
    RO.treasury = new ethers.Contract(cfg.treasuryAddress, ABI_TRS, readProvider);
    RO.fx = new ethers.Contract(cfg.fxAddress, ABI_FX, readProvider);
    RO.escrow = new ethers.Contract(cfg.escrowAddress, ABI_ESC, readProvider);
    RO.invoices = new ethers.Contract(cfg.invoicesAddress, ABI_INV, readProvider);
    RO.netting = new ethers.Contract(cfg.settlementAddress, ABI_NET, readProvider);
    RO.governor = new ethers.Contract(cfg.governorAddress, ABI_GOV, readProvider);
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
        if (data && data.accountsAddress && !localStorage.getItem(LS_ADDRESS)) accountsAddress = data.accountsAddress;
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
    accountsAddress = localStorage.getItem(LS_ADDRESS) || accountsAddress || "";

    readProvider = new ethers.JsonRpcProvider(rpcFor(chainIdPref));
    chainId = chainIdPref;

    if (accountsAddress && ethers.isAddress(accountsAddress)) {
      rebuildReadProvider();
    } else RO.accounts = null;

    $("#setup-banner").hidden = !!RO.accounts;
    $("#chain-badge").textContent = chainCfg(chainIdPref).name;
    $("#chain-badge").classList.toggle("ok", !!chainCfg(chainIdPref).rpc);
    $("#footer-address").textContent = RO.accounts ? shortAddr(accountsAddress) : "not configured";
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
    await refreshNetwork();
  }

  function renderWalletButton() {
    const btn = $("#btn-connect");
    btn.textContent = account ? shortAddr(account) : "Connect Wallet";
    btn.title = account || "";
  }

  async function refreshNetwork(silent) {
    if (!RO.accounts) return;
    try {
      const [rate, escrowed, fees, netted, myBal] = await Promise.all([
        RO.oracle.rate(cfg.usdAddress),
        RO.escrow.totalEscrowed(),
        RO.treasury.totalFeesCollected(),
        RO.netting.nettedTotal(),
        account ? RO.aeds.balanceOf(account) : 0n,
      ]);
      $("#rib-rate").textContent = (Number(rate) / 1e18).toFixed(2);
      $("#rib-escrow").textContent = fmtUnits(escrowed) + " AED-S";
      $("#rib-fees").textContent = fmtUnits(fees) + " AED-S";
      $("#rib-netted").textContent = fmtUnits(netted) + " AED-S";
      $("#rib-balance").textContent = account ? fmtUnits(myBal) + " AED-S" : "—";
      if (account) {
        $("#fx-usd").textContent = fmtUnits(await RO.usd.balanceOf(account)) + " USD";
      }
      $("#fx-fees").textContent = ((Number(await RO.fx.feeBps()) + Number(await RO.fx.spreadBps())) / 100).toFixed(1) + "%";

      // governance
      let rows = "";
      let pn = 0;
      try { while (true) { await RO.governor.proposals(pn); pn++; } } catch {}
      for (let i = pn - 1; i >= 0 && i >= pn - 8; i--) {
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
      console.warn("network:", err);
      const fallbacks = chainCfg(chainId ?? chainIdPref).rpcFallbacks || [];
      if (rpcFailures < fallbacks.length) {
        rpcFailures++;
        rebuildReadProvider();
        await refreshNetwork(silent);
        return;
      }
      rpcFailures = 0;
      rebuildReadProvider();
      if (!silent) toast("Could not read the network — " + (err.shortMessage || err.message || ""), "error", 9000);
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
      accountsAddress = ethers.getAddress(addr);
      localStorage.setItem(LS_ADDRESS, accountsAddress);
      location.reload();
    });

    $("#btn-send").addEventListener("click", async () => {
      try {
        await requireSigner();
        const to = $("#send-to").value.trim();
        const amt = $("#send-amount").value;
        const mode = Number($("#send-mode").value);
        if (!ethers.isAddress(to)) return toast("Invalid recipient address", "error");
        if (!amt || Number(amt) <= 0) return toast("Amount must be > 0", "error");
        const amount = ethers.parseEther(amt);
        const allowance = await RO.aeds.allowance(account, cfg.escrowAddress);
        if (allowance < amount) {
          const ap = await RO.aeds.connect(signer).approve(cfg.escrowAddress, amount * 2n);
          toast("⏳ Approve submitted — " + txLink(ap.hash), "info", 12000);
          await ap.wait();
        }
        const releaseAfter = mode === 1 ? BigInt(Math.floor(Date.now() / 1000) + 7 * 86400) : 0n;
        await send(
          RW.escrow.createPayment(ethers.getAddress(to), amount, mode, mode === 2 ? 2n : 0n, releaseAfter, 784, ethers.id("memo")),
          "Payment created"
        );
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-fx-to").addEventListener("click", async () => {
      try {
        await requireSigner();
        const amt = $("#fx-to-usd").value;
        if (!amt || Number(amt) <= 0) return toast("Amount must be > 0", "error");
        const amount = ethers.parseEther(amt);
        const allowance = await RO.aeds.allowance(account, cfg.fxAddress);
        if (allowance < amount) {
          const ap = await RO.aeds.connect(signer).approve(cfg.fxAddress, amount * 2n);
          toast("⏳ Approve submitted — " + txLink(ap.hash), "info", 12000);
          await ap.wait();
        }
        await send(RW.fx.convertTo(cfg.usdAddress, amount, 0n), "Converted to USD");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-fx-from").addEventListener("click", async () => {
      try {
        await requireSigner();
        const amt = $("#fx-to-aed").value;
        if (!amt || Number(amt) <= 0) return toast("Amount must be > 0", "error");
        const amount = ethers.parseEther(amt);
        const allowance = await RO.usd.allowance(account, cfg.fxAddress);
        if (allowance < amount) {
          const ap = await RO.usd.connect(signer).approve(cfg.fxAddress, amount * 2n);
          toast("⏳ Approve submitted — " + txLink(ap.hash), "info", 12000);
          await ap.wait();
        }
        await send(RW.fx.convertFrom(cfg.usdAddress, amount, 0n), "Converted to AED-S");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-invoice").addEventListener("click", async () => {
      try {
        await requireSigner();
        const payer = $("#inv-payer").value.trim();
        const value = $("#inv-value").value;
        if (!ethers.isAddress(payer)) return toast("Invalid payer address", "error");
        if (!value || Number(value) <= 0) return toast("Value must be > 0", "error");
        await send(
          RW.invoices.registerInvoice(ethers.getAddress(payer), ethers.parseEther(value), BigInt(Math.floor(Date.now() / 1000) + 30 * 86400), 784, "invoice"),
          "Invoice registered"
        );
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-propose").addEventListener("click", async () => {
      try {
        await requireSigner();
        const bps = $("#gov-fee").value;
        if (bps === "" || Number(bps) < 0 || Number(bps) > 1000) return toast("Fee must be 0–1000 bps", "error");
        const calldata = RO.escrow.interface.encodeFunctionData("setEscrowFee", [Number(bps)]);
        await send(RW.governor.propose(cfg.escrowAddress, 0n, calldata, "Set escrow fee to " + (Number(bps) / 100).toFixed(2) + "%"), "Proposal created");
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

    setInterval(() => { if (RO.accounts) refreshNetwork(); }, 30000);
  }

  async function requireSigner() {
    if (!RO.accounts || !accountsAddress) {
      const e = new Error("no accounts"); e.__handled = true;
      toast("Configure the accounts address first (Settings or the banner above)", "error");
      throw e;
    }
    if (!signer) {
      const e = new Error("no signer"); e.__handled = true;
      toast("Connect your wallet first", "error");
      throw e;
    }
    RW.escrow = new ethers.Contract(cfg.escrowAddress, ABI_ESC, signer);
    RW.fx = new ethers.Contract(cfg.fxAddress, ABI_FX, signer);
    RW.invoices = new ethers.Contract(cfg.invoicesAddress, ABI_INV, signer);
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
    const addr = $("#set-accounts-address").value.trim();
    if (addr && !ethers.isAddress(addr)) return toast("Invalid accounts address", "error");
    if (addr) {
      accountsAddress = ethers.getAddress(addr);
      localStorage.setItem(LS_ADDRESS, accountsAddress);
    } else localStorage.removeItem(LS_ADDRESS);
    localStorage.setItem(LS_CHAIN, $("#set-chain").value);
    location.reload();
  }

  document.addEventListener("DOMContentLoaded", init);
})();
