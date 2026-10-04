/* ============================================================
   Silsila dApp — application logic
   ethers.js v6 (UMD global), no build step.
   ============================================================ */

"use strict";

(function () {
  const $ = (s) => document.querySelector(s);
  const cfg = window.APP_CONFIG || {};
  const ABI_REG = window.SILSILAREGISTRY_ABI || [];
  const ABI_ORD = window.SILSILAORDERS_ABI || [];
  const ABI_SHP = window.SILSILASHIPMENTS_ABI || [];
  const ABI_PAY = window.SILSILAPAYMENTS_ABI || [];
  const ABI_CGO = window.SILSILACARGOINSURANCE_ABI || [];
  const ABI_REP = window.SILSILAREPUTATION_ABI || [];
  const ABI_GOV = window.SILSILAGOVERNOR_ABI || [];
  const ABI_AED = window.SILSILA_AEDS_ABI || [];

  const LS_ADDRESS = "silsila.registryAddress";
  const LS_CHAIN = "silsila.chainId";

  const GOV_STATES = ["Review", "Voting", "Timelock", "Succeeded", "Executed", "Defeated", "Canceled"];
  const ROLES = ["None", "Buyer", "Supplier", "Carrier", "Auditor", "Financier"];
  const MILES = ["None", "Created", "Packed", "InTransit", "Customs", "Delivered"];
  const OST = ["Open", "Accepted", "PartiallyFulfilled", "Fulfilled", "Canceled", "Rejected"];

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
    RO.orders = new ethers.Contract(cfg.ordersAddress, ABI_ORD, readProvider);
    RO.shipments = new ethers.Contract(cfg.shipmentsAddress, ABI_SHP, readProvider);
    RO.payments = new ethers.Contract(cfg.paymentsAddress, ABI_PAY, readProvider);
    RO.cargo = new ethers.Contract(cfg.cargoAddress, ABI_CGO, readProvider);
    RO.reputation = new ethers.Contract(cfg.reputationAddress, ABI_REP, readProvider);
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
    await refreshNetwork();
  }

  function renderWalletButton() {
    const btn = $("#btn-connect");
    btn.textContent = account ? shortAddr(account) : "Connect Wallet";
    btn.title = account || "";
  }

  async function refreshNetwork(silent) {
    if (!RO.registry) return;
    try {
      const [entityCount, escrowTotal, premiums, myScore, myRole] = await Promise.all([
        RO.registry.entityCount(),
        0n, // escrow count rendered from the balance below
        RO.cargo.totalPremiums(),
        account ? RO.reputation.scoreOf(account) : 500n,
        account ? RO.registry.roleOf(account) : 0n,
      ]);
      $("#strip-orders").textContent = String(entityCount) + " entities";
      $("#strip-escrow").textContent = fmtUnits(await RO.aeds.balanceOf(cfg.paymentsAddress)) + " AED-S";
      $("#strip-premiums").textContent = fmtUnits(premiums) + " AED-S";
      $("#strip-score").textContent = String(myScore);
      $("#strip-role").textContent = account ? ROLES[Number(myRole)] : "—";

      // orders
      let rows = "";
      let n = 0;
      try { while (true) { await RO.orders.orders(n); n++; } } catch {}
      for (let i = n - 1; i >= 0 && i >= n - 8; i--) {
        const o = await RO.orders.orders(i);
        rows +=
          '<div class="item-row"><span class="mono">#' + i + "</span>" +
          '<span class="muted small">' + fmtUnits(o.quantity) + " × " + fmtUnits(o.unitPrice).short + " AED-S · " + shortAddr(o.supplier) + "</span>" +
          '<span class="item-right">' + OST[Number(o.status)] + "</span>" +
          (Number(o.status) === 0 ? '<div class="item-actions"><button class="btn btn-ghost btn-sm" data-action="accept" data-id="' + i + '">Accept</button></div>' : "") +
          "</div>";
      }
      $("#order-list").innerHTML = rows || '<p class="muted">no orders yet</p>';

      // shipments
      let rows2 = "";
      let sn = 0;
      try { while (true) { await RO.shipments.shipments(sn); sn++; } } catch {}
      for (let i = sn - 1; i >= 0 && i >= sn - 8; i--) {
        const s = await RO.shipments.shipments(i);
        rows2 +=
          '<div class="item-row"><span class="mono">#' + i + "</span>" +
          '<span class="muted small">order ' + s.orderId.toString() + " · carrier " + shortAddr(s.carrier) + "</span>" +
          '<span class="item-right">' + MILES[Number(s.milestone)] + "</span></div>";
      }
      $("#ship-list").innerHTML = rows2 || '<p class="muted">no shipments yet</p>';

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
      registryAddress = ethers.getAddress(addr);
      localStorage.setItem(LS_ADDRESS, registryAddress);
      location.reload();
    });

    $("#btn-register").addEventListener("click", async () => {
      try {
        await requireSigner();
        await send(RW.registry.register(Number($("#reg-role").value), 784), "Registered");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-order").addEventListener("click", async () => {
      try {
        await requireSigner();
        const supplier = $("#ord-supplier").value.trim();
        const qty = $("#ord-qty").value, price = $("#ord-price").value;
        if (!ethers.isAddress(supplier)) return toast("Invalid supplier address", "error");
        if (!qty || Number(qty) < 1 || !price || Number(price) <= 0) return toast("Quantity ≥ 1 and price > 0", "error");
        await send(
          RW.orders.createOrder(ethers.getAddress(supplier), BigInt(qty), ethers.parseEther(price), BigInt(Math.floor(Date.now() / 1000) + 30 * 86400), 784, ethers.id("item"), false, ethers.ZeroHash),
          "Order created"
        );
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#order-list").addEventListener("click", async (e) => {
      const btn = e.target.closest("[data-action]");
      if (!btn || btn.dataset.action !== "accept") return;
      try {
        await requireSigner();
        await send(RW.orders.accept(BigInt(btn.dataset.id)), "Order accepted");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-ship").addEventListener("click", async () => {
      try {
        await requireSigner();
        const ord = $("#ship-order").value, carrier = $("#ship-carrier").value.trim();
        if (ord === "" || Number(ord) < 0 || !ethers.isAddress(carrier)) return toast("Order # and a valid carrier address", "error");
        await send(RW.shipments.createShipment(BigInt(ord), ethers.getAddress(carrier)), "Shipment created");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-advance").addEventListener("click", async () => {
      try {
        await requireSigner();
        const id = $("#adv-ship").value;
        if (id === "" || Number(id) < 0) return toast("Shipment # required", "error");
        const s = await RO.shipments.shipments(BigInt(id));
        const next = Number(s.milestone) + 1;
        if (next > 4) return toast("Advance to Customs first, then deliver", "info");
        await send(RW.shipments.updateMilestone(BigInt(id), next, ethers.id("location")), "Milestone advanced");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-deliver").addEventListener("click", async () => {
      try {
        await requireSigner();
        const id = $("#del-ship").value;
        if (id === "" || Number(id) < 0) return toast("Shipment # required", "error");
        await send(RW.shipments.deliver(BigInt(id), ethers.id("proof-of-delivery")), "Delivered");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-fund").addEventListener("click", async () => {
      try {
        await requireSigner();
        const ord = $("#fund-order").value;
        if (ord === "" || Number(ord) < 0) return toast("Order # required", "error");
        const o = await RO.orders.orders(BigInt(ord));
        const value = o.quantity * o.unitPrice;
        const allowance = await RO.aeds.allowance(account, cfg.paymentsAddress);
        if (allowance < value) {
          const ap = await RO.aeds.connect(signer).approve(cfg.paymentsAddress, value * 2n);
          toast("⏳ Approve submitted — " + txLink(ap.hash), "info", 12000);
          await ap.wait();
        }
        await send(RW.payments.fund(BigInt(ord), value), "Escrow funded");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-insure").addEventListener("click", async () => {
      try {
        await requireSigner();
        const ship = $("#ins-ship").value, cover = $("#ins-cover").value;
        if (ship === "" || Number(ship) < 0 || !cover || Number(cover) <= 0) return toast("Shipment # and cover > 0", "error");
        const amount = ethers.parseEther(cover);
        const premium = amount * (await RO.cargo.premiumBps()) / 10000n;
        const allowance = await RO.aeds.allowance(account, cfg.cargoAddress);
        if (allowance < premium) {
          const ap = await RO.aeds.connect(signer).approve(cfg.cargoAddress, premium * 2n);
          toast("⏳ Approve submitted — " + txLink(ap.hash), "info", 12000);
          await ap.wait();
        }
        await send(RW.cargo.insure(BigInt(ship), amount), "Cargo insured");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-propose").addEventListener("click", async () => {
      try {
        await requireSigner();
        const bps = $("#gov-fee").value;
        if (bps === "" || Number(bps) < 0 || Number(bps) > 1000) return toast("Fee must be 0–1000 bps", "error");
        const calldata = RO.payments.interface.encodeFunctionData("setFees", [Number(bps), 500, 300]);
        await send(RW.governor.propose(cfg.paymentsAddress, 0n, calldata, "Set platform fee to " + (Number(bps) / 100).toFixed(2) + "%"), "Proposal created");
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

    setInterval(() => { if (RO.registry) refreshNetwork(); }, 30000);
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
    RW.orders = new ethers.Contract(cfg.ordersAddress, ABI_ORD, signer);
    RW.shipments = new ethers.Contract(cfg.shipmentsAddress, ABI_SHP, signer);
    RW.payments = new ethers.Contract(cfg.paymentsAddress, ABI_PAY, signer);
    RW.cargo = new ethers.Contract(cfg.cargoAddress, ABI_CGO, signer);
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
