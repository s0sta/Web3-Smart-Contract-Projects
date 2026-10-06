/* ============================================================
   Ataa dApp — application logic
   ethers.js v6 (UMD global), no build step.
   ============================================================ */

"use strict";

(function () {
  const $ = (s) => document.querySelector(s);
  const cfg = window.APP_CONFIG || {};
  const ABI_REG = window.ATAAREGISTRY_ABI || [];
  const ABI_ORC = window.ATAAORACLE_ABI || [];
  const ABI_ZKT = window.ATAAZAKAT_ABI || [];
  const ABI_VLT = window.ATAAVAULT_ABI || [];
  const ABI_DON = window.ATAADONATIONS_ABI || [];
  const ABI_ALC = window.ATAAALLOCATIONS_ABI || [];
  const ABI_SPO = window.ATAASPONSORSHIPS_ABI || [];
  const ABI_GOV = window.ATAAGOVERNOR_ABI || [];
  const ABI_AED = window.ATAA_AEDS_ABI || [];

  const LS_ADDRESS = "ataa.registryAddress";
  const LS_CHAIN = "ataa.chainId";

  const GOV_STATES = ["Review", "Voting", "Timelock", "Succeeded", "Executed", "Defeated", "Canceled"];
  const CLASSES = ["None", "Cash", "Gold", "Silver", "Crypto", "Produce", "Livestock", "Rikaz"];
  const CATS = ["None", "Orphans", "Families", "Education", "Medical", "Food", "Water", "Emergency"];

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
    RO.zakat = new ethers.Contract(cfg.zakatAddress, ABI_ZKT, readProvider);
    RO.vault = new ethers.Contract(cfg.vaultAddress, ABI_VLT, readProvider);
    RO.donations = new ethers.Contract(cfg.donationsAddress, ABI_DON, readProvider);
    RO.allocations = new ethers.Contract(cfg.allocationsAddress, ABI_ALC, readProvider);
    RO.sponsorships = new ethers.Contract(cfg.sponsorshipsAddress, ABI_SPO, readProvider);
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
      const [pool, beneficiaries, nisab] = await Promise.all([
        RO.vault.poolBalance(),
        RO.registry.beneficiaryCount(),
        RO.zakat.cashNisab(),
      ]);
      $("#strip-pool").textContent = fmtUnits(pool) + " AED-S";
      $("#strip-beneficiaries").textContent = String(beneficiaries);
      $("#zk-nisab").textContent = fmtUnits(nisab) + " AED-S";

      if (account) {
        const report = await RO.vault.donorReport(account);
        $("#strip-given").textContent = fmtUnits(report.totalGiven) + " AED-S";
        $("#strip-alloc").textContent = fmtUnits(report.totalAllocated) + " AED-S";
        $("#strip-unalloc").textContent = fmtUnits(report.totalUnallocated) + " AED-S";

        // tracking rows
        let rows = "";
        for (const cid of report.ids) {
          const c = await RO.vault.contributions(cid);
          const outs = await RO.vault.outflowsOfList(cid);
          let where = "still in the pool";
          if (outs.length > 0) {
            const parts = [];
            for (const oid of outs) {
              const o = await RO.vault.outflows(oid);
              parts.push(fmtUnits(o.amount).short + " → beneficiary #" + o.beneficiaryId.toString());
            }
            where = parts.join(" · ");
          }
          rows +=
            '<div class="item-row"><span class="mono">#' + cid.toString() + "</span>" +
            '<span class="muted small">' + fmtUnits(c.amount).short + " AED-S · " + (Number(c.zakatClass) === 0 ? "sadaqa" : "zakat (" + CLASSES[Number(c.zakatClass)] + ")") + "</span>" +
            '<span class="item-right">' + where + "</span></div>";
        }
        $("#track-list").innerHTML = rows || '<p class="muted">no contributions yet</p>';

        // my zakat position
        const ac = BigInt($("#zk-class").value);
        const pos = await RO.zakat.positions(account, ac);
        $("#zk-due").textContent = fmtUnits(await RO.zakat.due(account, ac)) + " AED-S";
      } else {
        $("#strip-given").textContent = "—";
        $("#zk-due").textContent = "—";
      }

      // beneficiaries
      let rows2 = "";
      for (let i = 0; i < Number(beneficiaries) && i < 8; i++) {
        const b = await RO.registry.beneficiaries(i);
        rows2 +=
          '<div class="item-row"><span class="mono">#' + i + "</span>" +
          '<span class="muted small">' + CATS[Number(b.category)] + " · " + fmtUnits(b.monthlyNeed).short + "/mo</span>" +
          '<span class="item-right">' + (b.active ? "VERIFIED" : "INACTIVE") + "</span></div>";
      }
      $("#ben-list").innerHTML = rows2 || '<p class="muted">no beneficiaries yet</p>';

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

    $("#btn-register").addEventListener("click", async () => {
      try {
        await requireSigner();
        await send(RW.registry.registerDonor(), "Registered as donor");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-declare").addEventListener("click", async () => {
      try {
        await requireSigner();
        const ac = BigInt($("#zk-class").value);
        const amt = $("#zk-amount").value;
        if (!amt || Number(amt) <= 0) return toast("Enter your wealth first", "error");
        await send(RW.zakat.declareWealth(ac, ethers.parseEther(amt)), "Wealth declared");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-pay-zakat").addEventListener("click", async () => {
      try {
        await requireSigner();
        const ac = BigInt($("#zk-class").value);
        if (ac === 5n) {
          const kg = $("#zk-kg").value, price = $("#zk-pricekg").value;
          if (!kg || Number(kg) <= 0 || !price || Number(price) <= 0) return toast("Enter kg and price per kg", "error");
          const owed = (BigInt(kg) * ethers.parseEther(price) * 1000n) / 10000n;
          const allowance = await RO.aeds.allowance(account, cfg.vaultAddress);
          if (allowance < owed) {
            const ap = await RO.aeds.connect(signer).approve(cfg.vaultAddress, owed * 2n);
            toast("⏳ Approve submitted — " + txLink(ap.hash), "info", 12000);
            await ap.wait();
          }
          await send(RW.zakat.payProduceZakat(BigInt(kg), 0, ethers.parseEther(price)), "Produce zakat paid");
          return;
        }
        if (ac === 7n) {
          const amt = $("#zk-amount").value;
          if (!amt || Number(amt) <= 0) return toast("Enter the treasure value", "error");
          const owed = ethers.parseEther(amt) * 20n / 100n;
          const allowance = await RO.aeds.allowance(account, cfg.vaultAddress);
          if (allowance < owed) {
            const ap = await RO.aeds.connect(signer).approve(cfg.vaultAddress, owed * 2n);
            toast("⏳ Approve submitted — " + txLink(ap.hash), "info", 12000);
            await ap.wait();
          }
          await send(RW.zakat.payRikaz(ethers.parseEther(amt)), "Rikaz zakat paid");
          return;
        }
        const due = await RO.zakat.due(account, ac);
        if (due === 0n) return toast("Nothing due yet — check nisab and hawl", "info");
        const allowance = await RO.aeds.allowance(account, cfg.vaultAddress);
        if (allowance < due) {
          const ap = await RO.aeds.connect(signer).approve(cfg.vaultAddress, due * 2n);
          toast("⏳ Approve submitted — " + txLink(ap.hash), "info", 12000);
          await ap.wait();
        }
        await send(RW.zakat.payZakat(ac, due), "Zakat paid");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-sadaqa").addEventListener("click", async () => {
      try {
        await requireSigner();
        const amt = $("#sad-amount").value;
        if (!amt || Number(amt) <= 0) return toast("Amount must be > 0", "error");
        const amount = ethers.parseEther(amt);
        const allowance = await RO.aeds.allowance(account, cfg.vaultAddress);
        if (allowance < amount) {
          const ap = await RO.aeds.connect(signer).approve(cfg.vaultAddress, amount * 2n);
          toast("⏳ Approve submitted — " + txLink(ap.hash), "info", 12000);
          await ap.wait();
        }
        await send(RW.donations.donate(amount, 2), "Sadaqa donated");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-sponsor").addEventListener("click", async () => {
      try {
        await requireSigner();
        const bid = $("#sp-bid").value, amt = $("#sp-amount").value;
        if (bid === "" || Number(bid) < 0 || !amt || Number(amt) <= 0) return toast("Beneficiary # and monthly amount > 0", "error");
        await send(RW.sponsorships.pledge(BigInt(bid), ethers.parseEther(amt)), "Sponsorship started");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-propose").addEventListener("click", async () => {
      try {
        await requireSigner();
        const budget = $("#gov-budget").value;
        if (!budget || Number(budget) <= 0) return toast("Budget must be > 0", "error");
        const calldata = RO.allocations.interface.encodeFunctionData("setBudget", [1, ethers.parseEther(budget)]);
        await send(RW.governor.propose(cfg.allocationsAddress, 0n, calldata, "Set orphan budget to " + budget), "Proposal created");
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
    RW.zakat = new ethers.Contract(cfg.zakatAddress, ABI_ZKT, signer);
    RW.donations = new ethers.Contract(cfg.donationsAddress, ABI_DON, signer);
    RW.sponsorships = new ethers.Contract(cfg.sponsorshipsAddress, ABI_SPO, signer);
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
