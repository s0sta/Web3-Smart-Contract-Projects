/* ============================================================
   Mawarid dApp — application logic
   ethers.js v6 (UMD global), no build step.
   ============================================================ */

"use strict";

(function () {
  const $ = (s) => document.querySelector(s);
  const cfg = window.APP_CONFIG || {};
  const ABI_REG = window.MAWARIDASSETREGISTRY_ABI || [];
  const ABI_CMP = window.MAWARIDCOMPLIANCE_ABI || [];
  const ABI_SHR = window.MAWARIDSHARES_ABI || [];
  const ABI_PRI = window.MAWARIDPRIMARYMARKET_ABI || [];
  const ABI_SEC = window.MAWARIDSECONDARYMARKET_ABI || [];
  const ABI_DIS = window.MAWARIDRENTALDISTRIBUTOR_ABI || [];
  const ABI_TRS = window.MAWARIDTREASURY_ABI || [];
  const ABI_INS = window.MAWARIDINSURANCEFUND_ABI || [];
  const ABI_GOV = window.MAWARIDASSETGOVERNOR_ABI || [];
  const ABI_STB = window.MAWARID_STABLE_ABI || [];

  const LS_ADDRESS = "mawarid.registryAddress";
  const LS_CHAIN = "mawarid.chainId";

  const STATUS_NAMES = ["Draft", "Live", "Frozen", "Liquidated"];
  const PROP_NAMES = ["Appraise", "SetReserve", "ManagerChange", "Payout", "Rules"];
  const GOV_STATES = ["Review", "Voting", "Timelock", "Succeeded", "Executed", "Defeated", "Canceled"];

  /* ---------------- state ---------------- */
  let ifaceGov = null;
  let registryAddress = localStorage.getItem(LS_ADDRESS) || cfg.registryAddress || "";
  let chainIdPref = Number(localStorage.getItem(LS_CHAIN) || cfg.defaultChainId);
  let readProvider = null;
  let walletProvider = null;
  let signer = null;
  let account = null;
  let RO = {}; // read contracts
  let RW = {}; // write contracts
  let chainId = null;
  let rpcFailures = 0;
  let descriptions = {};

  const assetId = cfg.assetId || 0;

  /* ---------------- helpers ---------------- */

  function chainCfg(id) {
    return cfg.chains[id] || { name: "Unknown network", short: "unknown", rpc: null, explorer: null, currency: "ETH" };
  }
  function rpcFor(id) { return chainCfg(id).rpc || "https://ethereum-rpc.publicnode.com"; }
  function fallbackRpc(id) { return (chainCfg(id).rpcFallbacks || [])[rpcFailures % (chainCfg(id).rpcFallbacks?.length || 1)]; }
  function rebuildReadProvider() {
    const rpc = rpcFailures > 0 ? fallbackRpc(chainId ?? chainIdPref) : rpcFor(chainId ?? chainIdPref);
    readProvider = new ethers.JsonRpcProvider(rpc);
    RO.registry = new ethers.Contract(registryAddress, ABI_REG, readProvider);
    RO.governor = new ethers.Contract(cfg.governorAddress, ABI_GOV, readProvider);
    RO.shares = new ethers.Contract(cfg.sharesAddress, ABI_SHR, readProvider);
    RO.compliance = new ethers.Contract(cfg.complianceAddress, ABI_CMP, readProvider);
    RO.primary = new ethers.Contract(cfg.primaryAddress, ABI_PRI, readProvider);
    RO.secondary = new ethers.Contract(cfg.secondaryAddress, ABI_SEC, readProvider);
    RO.distributor = new ethers.Contract(cfg.distributorAddress, ABI_DIS, readProvider);
    RO.treasury = new ethers.Contract(cfg.treasuryAddress, ABI_TRS, readProvider);
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
      rebuildReadProvider();
    } else RO.registry = null;

    $("#setup-banner").hidden = !!RO.registry;
    $("#chain-badge").textContent = chainCfg(chainIdPref).name;
    $("#chain-badge").classList.toggle("ok", !!chainCfg(chainIdPref).rpc);
    $("#footer-address").textContent = RO.registry ? shortAddr(registryAddress) : "not configured";
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
    await refreshPlatform();
  }

  function renderWalletButton() {
    const btn = $("#btn-connect");
    btn.textContent = account ? shortAddr(account) : "Connect Wallet";
    btn.title = account || "";
  }

  async function refreshPlatform(silent) {
    if (!RO.registry) return;
    try {
      const a = await RO.registry.assets(assetId);
      $("#ticker-name").textContent = a.name;
      $("#ticker-appraisal").textContent = "$" + fmtUnits(a.appraisalUsd);
      $("#ticker-issued").textContent = fmtUnits(a.issuedShares) + " / " + fmtUnits(a.totalShares);
      $("#ticker-status").innerHTML = '<span class="status-pill ' + (Number(a.status) === 1 ? "status-ok" : "status-bad") + '">' + STATUS_NAMES[Number(a.status)] + "</span>";
      $("#ticker-distributed").textContent = fmtUnits(await RO.distributor.totalDistributed(assetId)) + " AED-S";

      const [volume, fees, feeBps] = await Promise.all([
        RO.secondary.totalVolume(),
        RO.secondary.totalFees(),
        RO.secondary.feeBps(),
      ]);
      $("#ex-volume").textContent = fmtUnits(volume) + " shares";
      $("#ex-fees").textContent = fmtUnits(fees) + " AED-S";
      $("#ex-feeBps").textContent = (Number(feeBps) / 100).toFixed(1) + "%";

      // open orders
      let orders = "";
      let openCount = 0;
      let n = 0;
      try { while (true) { await RO.secondary.orders(n); n++; } } catch {}
      for (let i = n - 1; i >= 0 && i >= n - 10; i--) {
        const o = await RO.secondary.orders(i);
        if (!o.active) continue;
        openCount++;
        orders +=
          '<div class="item-row"><span class="mono">#' + i + "</span>" +
          '<span class="muted small">' + fmtUnits(o.remaining).short + " shares @" + fmtUnits(o.pricePerShare).short + "</span>" +
          '<span class="item-right">' + shortAddr(o.seller) + "</span>" +
          '<div class="item-actions"><button class="btn btn-ghost btn-sm" data-action="fill" data-id="' + i + '">Fill all</button>' +
          '<button class="btn btn-ghost btn-sm" data-action="cancel-order" data-id="' + i + '">Cancel</button></div></div>';
      }
      $("#order-list").innerHTML = orders || '<p class="muted">no open orders</p>';
      $("#exchange-note").textContent = openCount === 0 ? "no open orders" : openCount + " open";

      // proposals
      let props = "";
      let pn = 0;
      try { while (true) { await RO.governor.proposals(pn); pn++; } } catch {}
      for (let i = pn - 1; i >= 0 && i >= pn - 8; i--) {
        const p = await RO.governor.proposals(i);
        const st = Number(await RO.governor.state(i));
        props +=
          '<div class="item-row"><span class="mono">#' + i + "</span>" +
          '<span class="muted small">' + PROP_NAMES[Number(p.pType)] + " · " + (p.description || "") + "</span>" +
          '<span class="item-right">' + GOV_STATES[st] + "</span>" +
          (st === 1 ? '<div class="item-actions"><button class="btn btn-ghost btn-sm" data-action="vote-for" data-id="' + i + '">For</button><button class="btn btn-ghost btn-sm" data-action="vote-against" data-id="' + i + '">Against</button></div>' : "") +
          (st === 3 ? '<div class="item-actions"><button class="btn btn-primary btn-sm" data-action="execute" data-id="' + i + '">Execute</button></div>' : "") +
          "</div>";
      }
      $("#prop-list").innerHTML = props || '<p class="muted">no proposals yet</p>';
      $("#gov-note").textContent = pn === 0 ? "no proposals yet" : pn + " on-chain";

      // my portfolio
      if (account) {
        const [bal, claimable, kyc] = await Promise.all([
          RO.shares.balanceOf(account),
          RO.distributor.claimable(assetId, account),
          RO.compliance.canHold(assetId, account),
        ]);
        $("#inv-shares").textContent = fmtUnits(bal) + " shares";
        $("#inv-claimable").textContent = fmtUnits(claimable) + " AED-S";
        $("#inv-kyc").innerHTML = kyc
          ? '<span class="status-pill status-ok">PASSED</span>'
          : '<span class="status-pill status-bad">NONE</span>';
      } else {
        $("#inv-shares").textContent = "—";
        $("#inv-claimable").textContent = "—";
        $("#inv-kyc").textContent = "—";
      }
    } catch (err) {
      console.warn("platform:", err);
      const fallbacks = chainCfg(chainId ?? chainIdPref).rpcFallbacks || [];
      if (rpcFailures < fallbacks.length) {
        rpcFailures++;
        rebuildReadProvider();
        await refreshPlatform(silent);
        return;
      }
      rpcFailures = 0;
      rebuildReadProvider();
      if (!silent) toast("Could not read the platform — " + (err.shortMessage || err.message || ""), "error", 9000);
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

    $("#btn-subscribe").addEventListener("click", async () => {
      try {
        await requireSigner();
        const n = $("#sub-amount").value;
        if (!n || Number(n) <= 0) return toast("Shares must be ≥ 1", "error");
        const amount = ethers.parseEther(n);
        const phase = await RO.primary.phases(0);
        const cost = (amount * phase.pricePerShare) / ethers.parseEther("1");
        const allowance = await RO.stable.allowance(account, cfg.primaryAddress);
        if (allowance < cost) {
          const ap = await RO.stable.connect(signer).approve(cfg.primaryAddress, cost * 2n);
          toast("⏳ Approve submitted — " + txLink(ap.hash), "info", 12000);
          await ap.wait();
        }
        await send(RW.primary.subscribe(0, amount), "Subscribed");
        $("#sub-amount").value = "";
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-claim-alloc").addEventListener("click", async () => {
      try {
        await requireSigner();
        await send(RW.primary.claimAllocation(0), "Shares claimed");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-claim-rent").addEventListener("click", async () => {
      try {
        await requireSigner();
        await send(RW.distributor.claim(assetId), "Rent claimed");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-sell").addEventListener("click", async () => {
      try {
        await requireSigner();
        const n = $("#sell-amount").value;
        const price = $("#sell-price").value;
        if (!n || Number(n) <= 0) return toast("Shares must be ≥ 1", "error");
        if (!price || Number(price) <= 0) return toast("Price must be > 0", "error");
        const amount = ethers.parseEther(n);
        const allowance = await RO.shares.allowance(account, cfg.secondaryAddress);
        if (allowance < amount) {
          const ap = await RO.shares.connect(signer).approve(cfg.secondaryAddress, amount * 2n);
          toast("⏳ Share approve submitted — " + txLink(ap.hash), "info", 12000);
          await ap.wait();
        }
        await send(RW.secondary.placeOrder(assetId, amount, ethers.parseEther(price)), "Order placed");
        $("#sell-amount").value = ""; $("#sell-price").value = "";
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#order-list").addEventListener("click", async (e) => {
      const btn = e.target.closest("[data-action]");
      if (!btn) return;
      const id = BigInt(btn.dataset.id);
      try {
        await requireSigner();
        if (btn.dataset.action === "fill") {
          const o = await RO.secondary.orders(id);
          const cost = (o.remaining * o.pricePerShare) / ethers.parseEther("1");
          const allowance = await RO.stable.allowance(account, cfg.secondaryAddress);
          if (allowance < cost) {
            const ap = await RO.stable.connect(signer).approve(cfg.secondaryAddress, cost * 2n);
            toast("⏳ Approve submitted — " + txLink(ap.hash), "info", 12000);
            await ap.wait();
          }
          await send(RW.secondary.fillOrder(id, o.remaining), "Order filled");
        } else {
          await send(RW.secondary.cancelOrder(id), "Order canceled");
        }
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#prop-list").addEventListener("click", async (e) => {
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

    $("#btn-appraise-propose").addEventListener("click", async () => {
      try {
        await requireSigner();
        const v = $("#appraise-value").value;
        if (!v || Number(v) <= 0) return toast("Valuation must be > 0", "error");
        const calldata = RO.registry.interface.encodeFunctionData("appraise", [BigInt(assetId), ethers.parseEther(v)]);
        await send(RW.governor.propose(0, BigInt(assetId), cfg.registryAddress, 0n, calldata, "Revalue to $" + v), "Proposal created");
        $("#appraise-value").value = "";
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-record-income").addEventListener("click", async () => {
      try {
        await requireSigner();
        const amt = $("#income-amount").value;
        if (!amt || Number(amt) <= 0) return toast("Amount must be > 0", "error");
        const amount = ethers.parseEther(amt);
        const allowance = await RO.stable.allowance(account, cfg.distributorAddress);
        if (allowance < amount) {
          const ap = await RO.stable.connect(signer).approve(cfg.distributorAddress, amount * 2n);
          toast("⏳ Approve submitted — " + txLink(ap.hash), "info", 12000);
          await ap.wait();
        }
        await send(RW.distributor.recordIncome(assetId, amount), "Income recorded");
        $("#income-amount").value = "";
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-distribute").addEventListener("click", async () => {
      try {
        await requireSigner();
        await send(RW.distributor.distribute(assetId), "Epoch distributed");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    setInterval(() => { if (RO.registry) refreshPlatform(); }, 30000);
  }

  async function requireSigner() {
    if (!RO.registry || !registryAddress) {
      const e = new Error("no registry"); e.__handled = true;
      toast("Configure the registry address first (Settings or the banner above)", "error");
      throw e;
    }
    if (!signer) {
      const e = new Error("no signer"); e.__handled = true;
      toast("Connect your wallet first", "error");
      throw e;
    }
    RW.registry = new ethers.Contract(registryAddress, ABI_REG, signer);
    RW.shares = new ethers.Contract(cfg.sharesAddress, ABI_SHR, signer);
    RW.primary = new ethers.Contract(cfg.primaryAddress, ABI_PRI, signer);
    RW.secondary = new ethers.Contract(cfg.secondaryAddress, ABI_SEC, signer);
    RW.distributor = new ethers.Contract(cfg.distributorAddress, ABI_DIS, signer);
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
