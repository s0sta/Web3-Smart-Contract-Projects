/* ============================================================
   Taqa dApp — application logic
   ethers.js v6 (UMD global), no build step.
   ============================================================ */

"use strict";

(function () {
  const $ = (s) => document.querySelector(s);
  const cfg = window.APP_CONFIG || {};
  const ABI_REG = window.TAQAREGISTRY_ABI || [];
  const ABI_ORC = window.TAQAORACLE_ABI || [];
  const ABI_MTR = window.TAQAMETERS_ABI || [];
  const ABI_CRT = window.TAQACERTIFICATES_ABI || [];
  const ABI_CBN = window.TAQACARBON_ABI || [];
  const ABI_TRS = window.TAQATREASURY_ABI || [];
  const ABI_MKT = window.TAQAMARKET_ABI || [];
  const ABI_P2P = window.TAQAP2P_ABI || [];
  const ABI_RET = window.TAQARETIREMENT_ABI || [];
  const ABI_GOV = window.TAQAGOVERNOR_ABI || [];
  const ABI_AED = window.TAQA_AEDS_ABI || [];

  const LS_ADDRESS = "taqa.registryAddress";
  const LS_CHAIN = "taqa.chainId";

  const GOV_STATES = ["Review", "Voting", "Timelock", "Succeeded", "Executed", "Defeated", "Canceled"];

  /* ---------------- state ---------------- */
  let ifaceGov = null;
  let registryAddress = localStorage.getItem(LS_ADDRESS) || cfg.registryAddress || "";
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
    RO.registry = new ethers.Contract(registryAddress, ABI_REG, readProvider);
    RO.oracle = new ethers.Contract(cfg.oracleAddress, ABI_ORC, readProvider);
    RO.meters = new ethers.Contract(cfg.metersAddress, ABI_MTR, readProvider);
    RO.certificates = new ethers.Contract(cfg.certificatesAddress, ABI_CRT, readProvider);
    RO.carbon = new ethers.Contract(cfg.carbonAddress, ABI_CBN, readProvider);
    RO.treasury = new ethers.Contract(cfg.treasuryAddress, ABI_TRS, readProvider);
    RO.market = new ethers.Contract(cfg.marketAddress, ABI_MKT, readProvider);
    RO.p2p = new ethers.Contract(cfg.p2pAddress, ABI_P2P, readProvider);
    RO.retirement = new ethers.Contract(cfg.retirementAddress, ABI_RET, readProvider);
    RO.governor = new ethers.Contract(cfg.governorAddress, ABI_GOV, readProvider);
    RO.aeds = new ethers.Contract(cfg.aedsAddress, ABI_AED, readProvider);
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
    await refreshGrid();
  }

  function renderWalletButton() {
    const btn = $("#btn-connect");
    btn.textContent = account ? shortAddr(account) : "Connect Wallet";
    btn.title = account || "";
  }

  async function refreshGrid(silent) {
    if (!RO.registry) return;
    try {
      const [tariff, recSupply, carbonSupply, myRec, myCarbon, myRetired] = await Promise.all([
        RO.oracle.price(cfg.aedsAddress),
        RO.certificates.totalSupply(),
        RO.carbon.totalSupply(),
        account ? RO.certificates.balanceOf(account) : 0n,
        account ? RO.carbon.balanceOf(account) : 0n,
        account ? RO.retirement.retiredRec(account) : 0n,
      ]);
      $("#strip-tariff").textContent = (Number(tariff) / 1e18).toFixed(2) + " AED/kWh";
      $("#strip-rec").textContent = String(recSupply) + " RECs";
      $("#strip-carbon").textContent = String(carbonSupply) + " tCO2e";
      $("#strip-holdings").textContent = account ? String(myRec) + " REC · " + String(myCarbon) + " tCO2e" : "—";
      $("#strip-retired").textContent = account ? String(myRetired) + " REC" : "—";

      // open orders
      let rows = "";
      let n = 0;
      try { while (true) { await RO.market.orders(n); n++; } } catch {}
      for (let i = n - 1; i >= 0 && i >= n - 8; i--) {
        const o = await RO.market.orders(i);
        if (!o.active) continue;
        rows +=
          '<div class="item-row"><span class="mono">#' + i + "</span>" +
          '<span class="muted small">' + (Number(o.kind) === 0 ? "REC" : "Carbon") + " " + o.amount.toString() + " @ " + (Number(o.price) / 1e18).toFixed(1) + "</span>" +
          '<span class="item-right">' + shortAddr(o.seller) + "</span>" +
          '<div class="item-actions"><button class="btn btn-ghost btn-sm" data-action="fill" data-id="' + i + '">Fill all</button></div></div>';
      }
      $("#order-list").innerHTML = rows || '<p class="muted">no open orders</p>';

      // governance
      let rows3 = "";
      let pn = 0;
      try { while (true) { await RO.governor.proposals(pn); pn++; } } catch {}
      for (let i = pn - 1; i >= 0 && i >= pn - 8; i--) {
        const p = await RO.governor.proposals(i);
        const st = Number(await RO.governor.state(i));
        rows3 +=
          '<div class="item-row"><span class="mono">#' + i + "</span>" +
          '<span class="muted small">' + (p.description || "") + "</span>" +
          '<span class="item-right">' + GOV_STATES[st] + "</span>" +
          (st === 1 ? '<div class="item-actions"><button class="btn btn-ghost btn-sm" data-action="vote-for" data-id="' + i + '">For</button><button class="btn btn-ghost btn-sm" data-action="vote-against" data-id="' + i + '">Against</button></div>' : "") +
          (st === 3 ? '<div class="item-actions"><button class="btn btn-primary btn-sm" data-action="execute" data-id="' + i + '">Execute</button></div>' : "") +
          "</div>";
      }
      $("#gov-list").innerHTML = rows3 || '<p class="muted">no proposals yet</p>';
    } catch (err) {
      console.warn("grid:", err);
      const fallbacks = chainCfg(chainId ?? chainIdPref).rpcFallbacks || [];
      if (rpcFailures < fallbacks.length) {
        rpcFailures++;
        rebuildReadProvider();
        await refreshGrid(silent);
        return;
      }
      rpcFailures = 0;
      rebuildReadProvider();
      if (!silent) toast("Could not read the grid — " + (err.shortMessage || err.message || ""), "error", 9000);
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

    $("#btn-register").addEventListener("click", async () => {
      try {
        await requireSigner();
        await send(RW.registry.register(1, 784), "Registered as producer");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-meter").addEventListener("click", async () => {
      try {
        await requireSigner();
        const cap = $("#meter-capacity").value;
        if (!cap || Number(cap) < 1) return toast("Capacity must be ≥ 1 W", "error");
        await send(RW.meters.registerMeter(ethers.id("meter-" + Date.now()), BigInt(cap)), "Meter registered");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-mint").addEventListener("click", async () => {
      try {
        await requireSigner();
        const meter = $("#mint-meter").value, amount = $("#mint-amount").value;
        if (meter === "" || Number(meter) < 0 || !amount || Number(amount) < 1) return toast("Meter # and amount ≥ 1", "error");
        await send(RW.certificates.mint(BigInt(meter), BigInt(amount)), "Certificates minted");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-sell").addEventListener("click", async () => {
      try {
        await requireSigner();
        const amount = $("#sell-amount").value, price = $("#sell-price").value;
        if (!amount || Number(amount) < 1 || !price || Number(price) <= 0) return toast("Amount ≥ 1 and price > 0", "error");
        await send(RW.market.placeOrder(0, ethers.parseEther(price), BigInt(amount)), "Order placed");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#order-list").addEventListener("click", async (e) => {
      const btn = e.target.closest("[data-action]");
      if (!btn || btn.dataset.action !== "fill") return;
      const id = BigInt(btn.dataset.id);
      try {
        await requireSigner();
        const o = await RO.market.orders(id);
        const cost = o.amount * o.price;
        const fee = cost * (await RO.market.feeBps()) / 10000n;
        const allowance = await RO.aeds.allowance(account, cfg.marketAddress);
        if (allowance < cost + fee) {
          const ap = await RO.aeds.connect(signer).approve(cfg.marketAddress, (cost + fee) * 2n);
          toast("⏳ Approve submitted — " + txLink(ap.hash), "info", 12000);
          await ap.wait();
        }
        await send(RW.market.fill(id, o.amount), "Order filled");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-p2p").addEventListener("click", async () => {
      try {
        await requireSigner();
        const kwh = $("#p2p-kwh").value, price = $("#p2p-price").value;
        if (!kwh || Number(kwh) < 1 || !price || Number(price) <= 0) return toast("kWh ≥ 1 and price > 0", "error");
        await send(RW.p2p.postOffer(ethers.parseEther(kwh), ethers.parseEther(price)), "Offer posted");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-retire").addEventListener("click", async () => {
      try {
        await requireSigner();
        const amount = $("#ret-amount").value, claim = $("#ret-claim").value.trim();
        if (!amount || Number(amount) < 1 || !claim) return toast("Amount ≥ 1 and a claim name", "error");
        await send(RW.retirement.retireRec(BigInt(amount), claim), "Certificates retired");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-propose").addEventListener("click", async () => {
      try {
        await requireSigner();
        const bps = $("#gov-fee").value;
        if (bps === "" || Number(bps) < 0 || Number(bps) > 1000) return toast("Fee must be 0–1000 bps", "error");
        const calldata = RO.p2p.interface.encodeFunctionData("setFee", [Number(bps)]);
        await send(RW.governor.propose(cfg.p2pAddress, 0n, calldata, "Set P2P fee to " + (Number(bps) / 100).toFixed(2) + "%"), "Proposal created");
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

    setInterval(() => { if (RO.registry) refreshGrid(); }, 30000);
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
    RW.meters = new ethers.Contract(cfg.metersAddress, ABI_MTR, signer);
    RW.certificates = new ethers.Contract(cfg.certificatesAddress, ABI_CRT, signer);
    RW.market = new ethers.Contract(cfg.marketAddress, ABI_MKT, signer);
    RW.p2p = new ethers.Contract(cfg.p2pAddress, ABI_P2P, signer);
    RW.retirement = new ethers.Contract(cfg.retirementAddress, ABI_RET, signer);
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
