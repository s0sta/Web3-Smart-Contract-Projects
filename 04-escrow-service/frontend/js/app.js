/* ============================================================
   TrustEscrow dApp — application logic
   ethers.js v6 (UMD global), no build step.
   ============================================================ */

"use strict";

(function () {
  const $ = (s) => document.querySelector(s);
  const cfg = window.APP_CONFIG || {};
  const ABI = window.TRUST_ESCROW_ABI || [];

  const LS_ADDRESS = "escrow.escrowAddress";
  const LS_CHAIN = "escrow.chainId";

  const STATES = ["Active", "Released", "Refunded", "Disputed", "Resolved"];

  /* ---------------- state ---------------- */
  let ifaceE = null;
  let escrowAddress = localStorage.getItem(LS_ADDRESS) || cfg.escrowAddress || "";
  let chainIdPref = Number(localStorage.getItem(LS_CHAIN) || cfg.defaultChainId);
  let readProvider = null;
  let walletProvider = null;
  let signer = null;
  let account = null;
  let escrowRO = null;
  let escrowRW = null;
  let escrowOwner = null;
  let chainId = null;
  let dealCount = 0;

  /* ---------------- helpers ---------------- */

  function chainCfg(id) {
    return cfg.chains[id] || { name: "Unknown network", short: "unknown", rpc: null, explorer: null, currency: "ETH" };
  }

  function rpcFor(id) {
    return chainCfg(id).rpc || "https://ethereum-rpc.publicnode.com";
  }

  function shortAddr(a) {
    if (!a) return "—";
    a = String(a);
    return a.length > 12 ? a.slice(0, 6) + "…" + a.slice(-4) : a;
  }

  function fmtEth(bn) {
    try {
      const f = ethers.formatEther(bn);
      const n = Number(f);
      const compact =
        n >= 1e6 ? new Intl.NumberFormat("en", { notation: "compact", maximumFractionDigits: 2 }).format(n) :
        n >= 1 ? new Intl.NumberFormat("en", { maximumFractionDigits: 4 }).format(n) :
        new Intl.NumberFormat("en", { maximumFractionDigits: 6 }).format(n);
      return { short: compact, full: f };
    } catch {
      return { short: "—", full: "—" };
    }
  }

  function explorerLink(path) {
    const ex = chainCfg(chainId ?? chainIdPref).explorer;
    return ex ? ex + path : null;
  }

  function txLink(hash) {
    const base = explorerLink("/tx/" + hash);
    return base ? '<a href="' + base + '" target="_blank" rel="noopener">' + shortAddr(hash) + " ↗</a>" : shortAddr(hash);
  }

  function addrLink(addr) {
    const base = explorerLink("/address/" + addr);
    return base ? '<a href="' + base + '" target="_blank" rel="noopener">' + shortAddr(addr) + "</a>" : shortAddr(addr);
  }

  function youBadge(addr) {
    return account && addr.toLowerCase() === account.toLowerCase() ? ' <span class="you">you</span>' : "";
  }

  /* ---------------- toasts & errors ---------------- */

  function toast(message, type = "info", ttl = 6000) {
    const box = $("#toast-container");
    const el = document.createElement("div");
    el.className = "toast " + type;
    el.innerHTML = message;
    box.appendChild(el);
    setTimeout(() => {
      el.classList.add("out");
      setTimeout(() => el.remove(), 300);
    }, ttl);
  }

  function decodeError(err) {
    if (!err) return "Unknown error";
    if (err.revert && err.revert.name) {
      const args = (err.revert.args || []).map((a) => (typeof a === "bigint" ? fmtEth(a).short : shortAddr(String(a)))).join(", ");
      return err.revert.name + (args ? "(" + args + ")" : "");
    }
    if (err.data && ifaceE) {
      try {
        const e = ifaceE.parseError(err.data);
        if (e) {
          const args = e.args.map((a) => (typeof a === "bigint" ? fmtEth(a).short : shortAddr(String(a)))).join(", ");
          return e.name + (args ? "(" + args + ")" : "");
        }
      } catch {}
    }
    if (err.shortMessage) {
      const m = err.shortMessage;
      if (m.includes("user rejected")) return "Transaction rejected in wallet";
      if (m.includes("insufficient funds")) return "Insufficient ETH for gas";
      return m;
    }
    return err.message || String(err);
  }

  /* ---------------- setup ---------------- */

  function spawnSparks() {
    const box = $("#sparks");
    for (let i = 0; i < 6; i++) {
      const a = document.createElement("i");
      a.className = "a";
      const b = document.createElement("i");
      b.className = "b";
      const y = 8 + Math.random() * 84;
      const d = 7 + Math.random() * 8;
      for (const el of [a, b]) {
        el.style.setProperty("--y", y + "%");
        el.style.setProperty("--d", d + "s");
        el.style.animationDelay = Math.random() * 8 + "s";
        box.appendChild(el);
      }
    }
  }

  async function init() {
    if (typeof ethers === "undefined") {
      toast("ethers.js failed to load — check your internet connection", "error", 12000);
      return;
    }
    ifaceE = new ethers.Interface(ABI);
    spawnSparks();

    try {
      const res = await fetch("api/config.php", { cache: "no-store" });
      if (res.ok) {
        const data = await res.json();
        if (data && data.escrowAddress && !localStorage.getItem(LS_ADDRESS)) {
          escrowAddress = data.escrowAddress;
        }
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
        if (accts.length > 0) {
          account = accts[0];
          signer = await walletProvider.getSigner();
        }
      } catch {}
    }

    bindUi();
    await refreshAll();
  }

  function applyAddressAndChain() {
    chainIdPref = Number(localStorage.getItem(LS_CHAIN) || cfg.defaultChainId);
    escrowAddress = localStorage.getItem(LS_ADDRESS) || escrowAddress || "";

    readProvider = new ethers.JsonRpcProvider(rpcFor(chainIdPref));
    chainId = chainIdPref;

    if (escrowAddress && ethers.isAddress(escrowAddress)) {
      escrowRO = new ethers.Contract(escrowAddress, ABI, readProvider);
    } else {
      escrowRO = null;
    }
    escrowRW = null;

    $("#setup-banner").hidden = !!escrowRO;
    $("#chain-badge").textContent = chainCfg(chainIdPref).name;
    $("#chain-badge").classList.toggle("ok", !!chainCfg(chainIdPref).rpc);
    $("#hero-address").textContent = escrowRO ? escrowAddress : "not configured";
    $("#footer-address").textContent = escrowRO ? shortAddr(escrowAddress) : "not configured";
    const ex = chainCfg(chainIdPref).explorer;
    $("#link-contract").href = escrowRO && ex ? ex + "/address/" + escrowAddress : "#";
    $("#link-contract").style.display = escrowRO && ex ? "" : "none";
    $("#footer-github").href = cfg.github || "#";
    $("#footer-explorer").href = ex || "#";
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
    if (!window.ethereum) {
      toast("No wallet detected — install MetaMask and refresh", "error", 9000);
      return;
    }
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
      account = null;
      signer = null;
      escrowRW = null;
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
        } catch {
          return false;
        }
      }
      return false;
    }
  }

  /* ---------------- rendering ---------------- */

  async function refreshAll() {
    renderWalletButton();
    await refreshStats();
    await refreshDeals();
    await refreshEvents();
    renderAdmin();
  }

  function renderWalletButton() {
    const btn = $("#btn-connect");
    btn.textContent = account ? shortAddr(account) : "Connect Wallet";
    btn.title = account || "";
  }

  async function refreshStats(silent) {
    if (!escrowRO) {
      $("#stat-deals").textContent = "—";
      $("#stat-fee").textContent = "—";
      $("#stat-fees").textContent = "—";
      $("#stat-role").textContent = "—";
      return;
    }
    try {
      const [count, fee, accrued, owner] = await Promise.all([
        escrowRO.dealCount(), escrowRO.feeBps(), escrowRO.accruedFees(), escrowRO.owner(),
      ]);
      escrowOwner = owner;
      dealCount = Number(count);
      $("#stat-deals").textContent = count.toString();
      $("#stat-fee").textContent = (Number(fee) / 100).toFixed(1) + "% (frozen per deal)";
      $("#stat-fees").textContent = fmtEth(accrued).short + " ETH";
      $("#stat-role").textContent = !account
        ? "connect your wallet to see your deal roles"
        : account.toLowerCase() === owner.toLowerCase()
          ? "👑 escrow owner"
          : "buyer / seller / arbiter depending on the deal";
    } catch (err) {
      console.warn("stats:", err);
      if (!silent) toast("Could not read the escrow — is the address correct on this network?", "error", 9000);
    }
  }

  async function refreshDeals() {
    const list = $("#deals-list");
    if (!escrowRO) {
      list.innerHTML = '<div class="card center muted">Deploy the escrow to see deals</div>';
      return;
    }
    try {
      $("#deals-note").textContent = dealCount === 0 ? "no deals yet" : dealCount + " on-chain";
      if (dealCount === 0) {
        list.innerHTML = '<div class="card center muted">No deals yet — open the first one above</div>';
        return;
      }
      const cards = [];
      for (let i = dealCount - 1; i >= 0; i--) {
        cards.push(await renderDealCard(i));
      }
      list.innerHTML = cards.join("");
    } catch (err) {
      console.warn("deals:", err);
      list.innerHTML = '<div class="card center muted">Could not load deals</div>';
    }
  }

  async function renderDealCard(id) {
    const [buyer, seller, arbiter, amount, dealFee, state] = await escrowRO.deals(id);
    const st = STATES[Number(state)];
    const aF = fmtEth(amount);
    const isBuyer = account && buyer.toLowerCase() === account.toLowerCase();
    const isSeller = account && seller.toLowerCase() === account.toLowerCase();
    const isArbiter = account && arbiter.toLowerCase() === account.toLowerCase();

    // lifecycle timeline
    let steps;
    if (st === "Active") {
      steps = [
        '<span class="t-step done"><span class="t-dot"></span>open</span><span class="t-conn filled"></span>' +
        '<span class="t-step now"><span class="t-dot"></span>' + (isSeller ? "release" : isBuyer ? "refund" : "in progress") + "</span>",
      ];
    } else if (st === "Released") {
      steps = '<span class="t-step done"><span class="t-dot"></span>open</span><span class="t-conn filled"></span><span class="t-step done"><span class="t-dot"></span>released</span>';
    } else if (st === "Refunded") {
      steps = '<span class="t-step done"><span class="t-dot"></span>open</span><span class="t-conn filled"></span><span class="t-step done"><span class="t-dot"></span>refunded</span>';
    } else if (st === "Disputed") {
      steps =
        '<span class="t-step done"><span class="t-dot"></span>open</span><span class="t-conn filled"></span>' +
        '<span class="t-step done"><span class="t-dot"></span>disputed</span><span class="t-conn"></span>' +
        '<span class="t-step now"><span class="t-dot"></span>resolve</span>';
    } else {
      // Resolved
      steps =
        '<span class="t-step done"><span class="t-dot"></span>open</span><span class="t-conn filled"></span>' +
        '<span class="t-step done"><span class="t-dot"></span>disputed</span><span class="t-conn filled"></span>' +
        '<span class="t-step done"><span class="t-dot"></span>resolved</span>';
    }

    let actions = "";
    if (st === "Active") {
      if (isSeller) {
        actions = '<button class="btn btn-primary btn-sm" data-action="release" data-id="' + id + '">Release funds</button>';
      }
      if (isBuyer) {
        actions += '<button class="btn btn-ghost btn-sm" data-action="refund" data-id="' + id + '">Refund</button>';
      }
      if (isBuyer || isSeller) {
        actions += '<button class="btn btn-danger btn-sm" data-action="dispute" data-id="' + id + '">Raise dispute</button>';
      }
      if (!actions) {
        actions = '<span class="muted" style="font-size:12px">active — awaiting seller release or buyer cancel</span>';
      }
    } else if (st === "Disputed" && isArbiter) {
      actions =
        '<div class="row">' +
        '<input type="number" id="resolve-' + id + '" placeholder="buyer gets (ETH)" min="0" step="any" style="flex:1" />' +
        '<button class="btn btn-accent btn-sm" data-action="resolve" data-id="' + id + '" style="width:auto">Resolve</button>' +
        "</div>";
    } else if (st === "Released") {
      actions = '<span class="stamp">released</span>';
    } else if (st === "Refunded") {
      actions = '<span class="stamp">refunded</span>';
    } else if (st === "Resolved") {
      actions = '<span class="stamp">resolved</span>';
    } else if (st === "Disputed") {
      actions = '<span class="muted" style="font-size:12px">frozen — waiting for the arbiter</span>';
    }

    return (
      '<div class="card deal-card" style="animation-delay:' + Math.min(id * 60, 300) + 'ms">' +
      "<div>" +
      '<div class="deal-top">' +
      "<h4>Deal #" + id + "</h4>" +
      '<span class="deal-state deal-' + st + (st === "Active" ? " pulse" : "") + '">' + st + "</span>" +
      "</div>" +
      '<div class="timeline">' + steps + "</div>" +
      '<div class="deal-parties">' +
      '<span>buyer: <span class="mono">' + addrLink(buyer) + youBadge(buyer) + "</span></span>" +
      '<span>seller: <span class="mono">' + addrLink(seller) + youBadge(seller) + "</span></span>" +
      '<span>arbiter: <span class="mono">' + addrLink(arbiter) + youBadge(arbiter) + "</span></span>" +
      "</div>" +
      "</div>" +
      '<div class="deal-side">' +
      '<span class="deal-amount">' + aF.short + " ETH</span>" +
      '<span class="deal-fee">frozen fee: ' + (Number(dealFee) / 100).toFixed(1) + "%</span>" +
      '<div class="deal-actions">' + actions + "</div>" +
      "</div>" +
      "</div>"
    );
  }

  function renderAdmin() {
    const isOwner = account && escrowOwner && account.toLowerCase() === escrowOwner.toLowerCase();
    $("#admin-section").hidden = !isOwner;
  }

  /* ---------------- event feed ---------------- */

  async function refreshEvents() {
    const tbody = $("#activity-body");
    if (!escrowRO) {
      tbody.innerHTML = '<tr><td colspan="4" class="muted center">Deploy the escrow to see activity</td></tr>';
      return;
    }
    try {
      const latest = await readProvider.getBlockNumber();
      const fromBlock = Math.max(0, latest - (cfg.eventLookbackBlocks || 50000));
      const logs = await readProvider.getLogs({ address: escrowAddress, fromBlock, toBlock: latest });
      const decoded = logs
        .map((l) => {
          try {
            return { ...ifaceE.parseLog({ topics: l.topics, data: l.data }), blockNumber: Number(l.blockNumber), index: Number(l.index), tx: l.transactionHash };
          } catch {
            return null;
          }
        })
        .filter(Boolean)
        .sort((a, b) => (b.blockNumber - a.blockNumber) || (b.index - a.index))
        .slice(0, 15);

      if (decoded.length === 0) {
        tbody.innerHTML = '<tr><td colspan="4" class="muted center">No events in the last ' + (cfg.eventLookbackBlocks || 50000) + " blocks</td></tr>";
      } else {
        tbody.innerHTML = decoded.map(renderEventRow).join("");
      }
      $("#events-note").textContent = "showing the latest " + decoded.length + " events";
    } catch (err) {
      tbody.innerHTML = '<tr><td colspan="4" class="muted center">Could not load events</td></tr>';
      console.warn("events:", err);
    }
  }

  function renderEventRow(ev) {
    let details = "";
    switch (ev.name) {
      case "DealOpened":
        details = "deal #" + ev.args.dealId + " · buyer " + addrLink(ev.args.buyer) + " → seller " + addrLink(ev.args.seller) + " · " + fmtEth(ev.args.amount).short + " ETH";
        break;
      case "DealReleased":
        details = "deal #" + ev.args.dealId + " · seller " + addrLink(ev.args.seller) + " got " + fmtEth(ev.args.amount).short + " ETH";
        break;
      case "DealRefunded":
        details = "deal #" + ev.args.dealId + " · buyer " + addrLink(ev.args.buyer) + " refunded " + fmtEth(ev.args.amount).short + " ETH";
        break;
      case "DisputeRaised":
        details = "deal #" + ev.args.dealId + " · raised by " + addrLink(ev.args.by);
        break;
      case "DisputeResolved":
        details = "deal #" + ev.args.dealId + " · arbiter " + addrLink(ev.args.arbiter) + " · buyer " + fmtEth(ev.args.buyerAmount).short + " / seller " + fmtEth(ev.args.sellerAmount).short;
        break;
      case "FeeCredited":
        details = "platform credited " + fmtEth(ev.args.amount).short + " ETH";
        break;
      case "FeesWithdrawn":
        details = "withdrew " + fmtEth(ev.args.amount).short + " ETH → " + addrLink(ev.args.to);
        break;
      default:
        details = Object.entries(ev.args).map(([k, v]) => k + ": " + shortAddr(String(v))).join(" · ");
    }
    return (
      "<tr>" +
      '<td><span class="ev-pill ev-' + ev.name + '">' + ev.name + "</span></td>" +
      '<td class="mono">' + details + "</td>" +
      '<td class="mono muted">' + ev.blockNumber + "</td>" +
      "<td>" + txLink(ev.tx) + "</td>" +
      "</tr>"
    );
  }

  /* ---------------- actions ---------------- */

  function bindUi() {
    $("#btn-connect").addEventListener("click", connect);
    $("#btn-settings").addEventListener("click", () => { $("#settings-panel").hidden = !$("#settings-panel").hidden; });
    $("#btn-cancel-settings").addEventListener("click", () => { $("#settings-panel").hidden = true; });
    $("#btn-save-settings").addEventListener("click", saveSettings);
    $("#btn-copy-address").addEventListener("click", copyAddress);
    $("#btn-refresh-events").addEventListener("click", refreshEvents);

    $("#form-setup").addEventListener("submit", (e) => {
      e.preventDefault();
      const addr = $("#setup-address").value.trim();
      if (!ethers.isAddress(addr)) return toast("That does not look like a valid address", "error");
      escrowAddress = ethers.getAddress(addr);
      localStorage.setItem(LS_ADDRESS, escrowAddress);
      location.reload();
    });

    // open deal
    $("#form-open").addEventListener("submit", async (e) => {
      e.preventDefault();
      try {
        await requireEscrow();
        const seller = $("#open-seller").value.trim();
        const arbiter = $("#open-arbiter").value.trim();
        const amount = $("#open-amount").value;
        if (!ethers.isAddress(seller) || !ethers.isAddress(arbiter)) return toast("Invalid seller/arbiter address", "error");
        if (!amount || Number(amount) <= 0) return toast("Deposit must be > 0", "error");

        const btn = e.target.querySelector("button");
        const original = btn.textContent;
        btn.disabled = true;
        btn.innerHTML = '<span class="spin">◌</span> Opening…';
        await send(escrowRW.openDeal(ethers.getAddress(seller), ethers.getAddress(arbiter), { value: ethers.parseEther(amount) }), "Deal opened");
        $("#open-seller").value = "";
        $("#open-arbiter").value = "";
        $("#open-amount").value = "";
        btn.disabled = false;
        btn.textContent = original;
      } catch (err) {
        const btn = e.target.querySelector("button");
        btn.disabled = false;
        btn.textContent = "Open deal";
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    // delegated deal actions
    $("#deals-list").addEventListener("click", async (e) => {
      const btn = e.target.closest("[data-action]");
      if (!btn) return;
      const id = Number(btn.dataset.id);
      const action = btn.dataset.action;
      try {
        await requireEscrow();
        const original = btn.textContent;
        btn.disabled = true;
        btn.innerHTML = '<span class="spin">◌</span>…';
        if (action === "release") {
          await send(escrowRW.release(id), "Deal released");
        } else if (action === "refund") {
          await send(escrowRW.refund(id), "Deal refunded");
        } else if (action === "dispute") {
          await send(escrowRW.dispute(id), "Dispute raised");
        } else if (action === "resolve") {
          const amt = $("#resolve-" + id).value;
          if (amt === "" || Number(amt) < 0) throw new Error("Enter the buyer amount (0 = seller wins)");
          await send(escrowRW.resolve(id, ethers.parseEther(amt)), "Dispute resolved");
        }
        btn.disabled = false;
        btn.textContent = original;
      } catch (err) {
        btn.disabled = false;
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    // admin
    $("#form-set-fee").addEventListener("submit", async (e) => {
      e.preventDefault();
      try {
        await requireEscrow();
        const bps = $("#fee-bps").value;
        if (bps === "" || Number(bps) < 0 || Number(bps) > 1000) return toast("Fee must be 0–1000 bps", "error");
        await send(escrowRW.setFeeBps(bps), "Fee updated");
      } catch (err) {
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });
    $("#form-withdraw-fees").addEventListener("submit", async (e) => {
      e.preventDefault();
      try {
        await requireEscrow();
        const to = $("#withdraw-to").value.trim();
        if (!ethers.isAddress(to)) return toast("Invalid recipient address", "error");
        await send(escrowRW.withdrawFees(to), "Fees withdrawn");
      } catch (err) {
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    // live refresh
    setInterval(() => { if (escrowRO) refreshStats(true); }, 15000);
  }

  async function requireEscrow() {
    if (!escrowRO || !escrowAddress) {
      const e = new Error("Configure the escrow address first");
      e.__handled = true;
      toast("Configure the escrow address first (Settings or the banner above)", "error");
      throw e;
    }
    if (!signer) {
      const e = new Error("Connect your wallet first");
      e.__handled = true;
      toast("Connect your wallet first", "error");
      throw e;
    }
    if (!escrowRW) escrowRW = new ethers.Contract(escrowAddress, ABI, signer);
  }

  async function send(txPromise, label) {
    const tx = await txPromise;
    toast("⏳ " + label + " submitted — " + txLink(tx.hash), "info", 12000);
    await tx.wait();
    toast("✅ " + label + " confirmed — " + txLink(tx.hash), "success", 9000);
    await refreshAll();
  }

  /* ---------------- settings ---------------- */

  function saveSettings() {
    const addr = $("#set-escrow-address").value.trim();
    if (addr && !ethers.isAddress(addr)) return toast("Invalid escrow address", "error");
    if (addr) {
      escrowAddress = ethers.getAddress(addr);
      localStorage.setItem(LS_ADDRESS, escrowAddress);
    } else {
      localStorage.removeItem(LS_ADDRESS);
    }
    localStorage.setItem(LS_CHAIN, $("#set-chain").value);
    location.reload();
  }

  function copyAddress() {
    if (!escrowAddress) return;
    navigator.clipboard.writeText(escrowAddress).then(
      () => toast("Address copied to clipboard", "success"),
      () => toast("Copy failed — address: " + escrowAddress, "info", 9000)
    );
  }

  /* ---------------- boot ---------------- */

  document.addEventListener("DOMContentLoaded", init);
})();
