/* ============================================================
   CrowdFund dApp — application logic
   ethers.js v6 (UMD global), no build step.
   ============================================================ */

"use strict";

(function () {
  const $ = (s) => document.querySelector(s);
  const cfg = window.APP_CONFIG || {};
  const ABI_F = window.CROWD_FUND_FACTORY_ABI || [];
  const ABI_C = window.CROWD_FUND_CAMPAIGN_ABI || [];

  const LS_ADDRESS = "crowdfund.factoryAddress";
  const LS_CHAIN = "crowdfund.chainId";

  /* ---------------- state ---------------- */
  let ifaceF = null;
  let ifaceC = null;
  let factoryAddress = localStorage.getItem(LS_ADDRESS) || cfg.factoryAddress || "";
  let chainIdPref = Number(localStorage.getItem(LS_CHAIN) || cfg.defaultChainId);
  let readProvider = null;
  let walletProvider = null;
  let signer = null;
  let account = null;
  let factoryRO = null;
  let factoryRW = null;
  let factoryOwner = null;
  let chainId = null;
  let campaignCache = []; // { id, addr, contract, data }
  let countdownTimer = null;

  const STATUS = ["Active", "Successful", "Failed"];

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

  function fmtCountdown(seconds) {
    if (seconds <= 0) return { text: "ended", ended: true };
    const d = Math.floor(seconds / 86400);
    const h = Math.floor((seconds % 86400) / 3600);
    const m = Math.floor((seconds % 3600) / 60);
    const s = seconds % 60;
    const pad = (x) => String(x).padStart(2, "0");
    return { text: (d > 0 ? d + "d " : "") + pad(h) + ":" + pad(m) + ":" + pad(s), ended: false };
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
    if (err.data) {
      for (const i of [ifaceC, ifaceF]) {
        if (!i) continue;
        try {
          const e = i.parseError(err.data);
          if (e) {
            const args = e.args.map((a) => (typeof a === "bigint" ? fmtEth(a).short : shortAddr(String(a)))).join(", ");
            return e.name + (args ? "(" + args + ")" : "");
          }
        } catch {}
      }
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

  function spawnCoins() {
    const box = $("#coins");
    for (let i = 0; i < 14; i++) {
      const c = document.createElement("i");
      c.style.left = Math.random() * 100 + "%";
      c.style.width = c.style.height = 6 + Math.random() * 10 + "px";
      c.style.animationDuration = 9 + Math.random() * 14 + "s";
      c.style.animationDelay = Math.random() * 12 + "s";
      box.appendChild(c);
    }
  }

  async function init() {
    if (typeof ethers === "undefined") {
      toast("ethers.js failed to load — check your internet connection", "error", 12000);
      return;
    }
    ifaceF = new ethers.Interface(ABI_F);
    ifaceC = new ethers.Interface(ABI_C);
    spawnCoins();

    try {
      const res = await fetch("api/config.php", { cache: "no-store" });
      if (res.ok) {
        const data = await res.json();
        if (data && data.factoryAddress && !localStorage.getItem(LS_ADDRESS)) {
          factoryAddress = data.factoryAddress;
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
    factoryAddress = localStorage.getItem(LS_ADDRESS) || factoryAddress || "";

    readProvider = new ethers.JsonRpcProvider(rpcFor(chainIdPref));
    chainId = chainIdPref;

    if (factoryAddress && ethers.isAddress(factoryAddress)) {
      factoryRO = new ethers.Contract(factoryAddress, ABI_F, readProvider);
    } else {
      factoryRO = null;
    }
    factoryRW = null;

    $("#setup-banner").hidden = !!factoryRO;
    $("#chain-badge").textContent = chainCfg(chainIdPref).name;
    $("#chain-badge").classList.toggle("ok", !!chainCfg(chainIdPref).rpc);
    $("#hero-address").textContent = factoryRO ? factoryAddress : "not configured";
    $("#footer-address").textContent = factoryRO ? shortAddr(factoryAddress) : "not configured";
    const ex = chainCfg(chainIdPref).explorer;
    $("#link-contract").href = factoryRO && ex ? ex + "/address/" + factoryAddress : "#";
    $("#link-contract").style.display = factoryRO && ex ? "" : "none";
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
      factoryRW = null;
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
    await refreshCampaigns();
    await refreshEvents();
    renderAdmin();
  }

  function renderWalletButton() {
    const btn = $("#btn-connect");
    btn.textContent = account ? shortAddr(account) : "Connect Wallet";
    btn.title = account || "";
  }

  async function refreshStats(silent) {
    if (!factoryRO) {
      $("#stat-campaigns").textContent = "—";
      $("#stat-fee").textContent = "—";
      $("#stat-fees").textContent = "—";
      return;
    }
    try {
      const [count, fee, accrued, owner] = await Promise.all([
        factoryRO.campaignCount(), factoryRO.feeBps(), factoryRO.accruedFees(), factoryRO.owner(),
      ]);
      factoryOwner = owner;
      $("#stat-campaigns").textContent = count.toString();
      $("#stat-fee").textContent = (Number(fee) / 100).toFixed(1) + "%";
      $("#stat-fees").textContent = fmtEth(accrued).short + " ETH";
    } catch (err) {
      console.warn("stats:", err);
      if (!silent) toast("Could not read the factory — is the address correct on this network?", "error", 9000);
    }
  }

  async function refreshCampaigns() {
    const grid = $("#campaigns-grid");
    if (!factoryRO) {
      grid.innerHTML = '<div class="card center muted" style="grid-column: 1 / -1">Deploy the factory to see campaigns</div>';
      return;
    }
    try {
      const count = Number(await factoryRO.campaignCount());
      $("#campaigns-note").textContent = count === 0 ? "no campaigns yet — launch the first one 🚀" : count + " on-chain";
      if (count === 0) {
        grid.innerHTML = '<div class="card center muted" style="grid-column: 1 / -1">No campaigns yet — be the first to launch one above</div>';
        return;
      }

      const promises = [];
      for (let i = 0; i < count; i++) {
        promises.push(factoryRO.allCampaigns(i));
      }
      const addrs = await Promise.all(promises);

      campaignCache = [];
      const cards = [];
      for (let i = 0; i < addrs.length; i++) {
        const c = new ethers.Contract(addrs[i], ABI_C, readProvider);
        const [creator, goal, deadline, pledged, status, claimed] = await Promise.all([
          c.creator(), c.goal(), c.deadline(), c.totalPledged(), c.status(), c.claimed(),
        ]);
        const entry = { id: i, addr: addrs[i], contract: c, creator, goal, deadline: Number(deadline), status: Number(status), claimed };
        campaignCache.push(entry);
        cards.push(await renderCampaignCard(entry));
      }
      grid.innerHTML = cards.join("");
      startCountdown();
    } catch (err) {
      console.warn("campaigns:", err);
      grid.innerHTML = '<div class="card center muted" style="grid-column: 1 / -1">Could not load campaigns</div>';
    }
  }

  async function renderCampaignCard(entry) {
    const st = STATUS[entry.status];
    const goalF = fmtEth(entry.goal);
    const pledgedF = fmtEth(entry.pledged);
    const pct = entry.goal > 0n ? Math.min(100, Number((entry.pledged * 10000n) / entry.goal) / 100) : 100;
    const now = Math.floor(Date.now() / 1000);
    const cd = fmtCountdown(entry.deadline - now);
    const isCreator = account && account.toLowerCase() === entry.creator.toLowerCase();
    let myPledge = 0n;
    if (account) myPledge = await entry.contract.pledged(account);

    let actions = "";
    if (entry.status === 0) {
      // Active
      if (isCreator) {
        actions = '<p class="muted" style="margin-top:8px">You created this campaign — creators cannot pledge to their own.</p>';
      } else {
        actions =
          '<div class="campaign-actions">' +
          '<input type="number" id="pledge-' + entry.id + '" placeholder="0.1" min="0" step="any" />' +
          '<button class="btn btn-primary" data-action="pledge" data-id="' + entry.id + '">Pledge</button>' +
          "</div>";
      }
    } else if (entry.status === 1) {
      // Successful
      if (isCreator && !entry.claimed) {
        actions = '<button class="btn btn-accent" data-action="claim" data-id="' + entry.id + '">Claim funds</button>';
      } else if (isCreator && entry.claimed) {
        actions = '<p class="muted" style="margin-top:8px">✔ Funds claimed</p>';
      } else {
        actions = '<p class="muted" style="margin-top:8px">Goal reached — campaign succeeded 🎉</p>';
      }
    } else {
      // Failed
      if (myPledge > 0n) {
        actions = '<button class="btn btn-ghost" data-action="refund" data-id="' + entry.id + '">Refund my ' + fmtEth(myPledge).short + " ETH</button>";
      } else {
        actions = '<p class="muted" style="margin-top:8px">Campaign failed — backers can pull their refunds.</p>';
      }
    }

    return (
      '<div class="card campaign" style="animation-delay:' + Math.min(entry.id * 70, 420) + 'ms">' +
      '<div class="campaign-top">' +
      '<h3>Campaign #' + entry.id + "</h3>" +
      '<span class="status-pill status-' + st + '"><span class="dot"></span>' + st + "</span>" +
      "</div>" +
      '<p class="meta">creator: <span class="mono">' + addrLink(entry.creator) + (isCreator ? " (you)" : "") + "</span></p>" +
      '<div class="progress"><div class="progress-fill" style="width:' + pct + '%"></div></div>' +
      '<div class="campaign-numbers"><span>' + pledgedF.short + " / " + goalF.short + " ETH</span><span>" + pct.toFixed(1) + "%</span></div>" +
      '<div class="campaign-countdown' + (cd.ended ? " ended" : "") + '" data-deadline="' + entry.deadline + '">⏳ ' + cd.text + "</div>" +
      (account ? '<div class="my-pledge">your pledge: ' + fmtEth(myPledge).short + " ETH</div>" : "") +
      actions +
      "</div>"
    );
  }

  function startCountdown() {
    if (countdownTimer) clearInterval(countdownTimer);
    countdownTimer = setInterval(() => {
      const now = Math.floor(Date.now() / 1000);
      let needsRefresh = false;
      document.querySelectorAll("[data-deadline]").forEach((el) => {
        const deadline = Number(el.dataset.deadline);
        const cd = fmtCountdown(deadline - now);
        el.textContent = "⏳ " + cd.text;
        el.classList.toggle("ended", cd.ended);
        if (cd.ended && !el.dataset.flipped) {
          el.dataset.flipped = "1";
          needsRefresh = true; // status may have changed once
        }
      });
      if (needsRefresh) refreshCampaigns();
    }, 1000);
  }

  function renderAdmin() {
    const isOwner = account && factoryOwner && account.toLowerCase() === factoryOwner.toLowerCase();
    $("#admin-section").hidden = !isOwner;
  }

  /* ---------------- event feed ---------------- */

  async function refreshEvents() {
    const tbody = $("#activity-body");
    if (!factoryRO) {
      tbody.innerHTML = '<tr><td colspan="4" class="muted center">Deploy the factory to see activity</td></tr>';
      return;
    }
    try {
      const latest = await readProvider.getBlockNumber();
      const fromBlock = Math.max(0, latest - (cfg.eventLookbackBlocks || 50000));

      const addresses = [factoryAddress];
      const cap = Math.min(Number(await factoryRO.campaignCount()), 30);
      for (let i = 0; i < cap; i++) addresses.push(await factoryRO.allCampaigns(i));

      const logs = await readProvider.getLogs({ address: addresses, fromBlock, toBlock: latest });
      const decoded = logs
        .map((l) => {
          let parsed = null;
          for (const i of [ifaceF, ifaceC]) {
            try {
              parsed = i.parseLog({ topics: l.topics, data: l.data });
              if (parsed) break;
            } catch {}
          }
          if (!parsed) return null;
          return { ...parsed, address: l.address, blockNumber: Number(l.blockNumber), index: Number(l.index), tx: l.transactionHash };
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
      case "CampaignCreated":
        details = "campaign #" + ev.args.id + " by " + addrLink(ev.args.creator) + " · goal " + fmtEth(ev.args.goal).short + " ETH";
        break;
      case "Pledged":
        details = addrLink(ev.args.backer) + " pledged " + fmtEth(ev.args.amount).short + " ETH → " + shortAddr(ev.address);
        break;
      case "Claimed":
        details = addrLink(ev.args.creator) + " claimed " + fmtEth(ev.args.amount).short + " ETH";
        break;
      case "Refunded":
        details = addrLink(ev.args.backer) + " refunded " + fmtEth(ev.args.amount).short + " ETH";
        break;
      case "FeeCredited":
        details = shortAddr(ev.address) + " credited " + fmtEth(ev.args.amount).short + " ETH";
        break;
      case "FeesWithdrawn":
        details = "platform withdrew " + fmtEth(ev.args.amount).short + " ETH → " + addrLink(ev.args.to);
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
      factoryAddress = ethers.getAddress(addr);
      localStorage.setItem(LS_ADDRESS, factoryAddress);
      location.reload();
    });

    // create campaign
    $("#form-create").addEventListener("submit", async (e) => {
      e.preventDefault();
      await requireFactory();
      const goal = $("#create-goal").value;
      const days = $("#create-days").value;
      if (!goal || Number(goal) <= 0) return toast("Goal must be > 0 ETH", "error");
      if (!days || Number(days) < 1) return toast("Duration must be at least 1 day", "error");
      const goalWei = ethers.parseEther(goal);
      const duration = Math.floor(Number(days) * 86400);
      const btn = e.target.querySelector("button");
      const original = btn.textContent;
      btn.disabled = true;
      btn.innerHTML = '<span class="spin">◌</span> Deploying…';
      try {
        await send(factoryRW.createCampaign(goalWei, duration), "Campaign created");
        $("#create-goal").value = "";
        $("#create-days").value = "";
      } catch (err) {
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      } finally {
        btn.disabled = false;
        btn.textContent = original;
      }
    });

    // delegated campaign actions (pledge / claim / refund)
    $("#campaigns-grid").addEventListener("click", async (e) => {
      const btn = e.target.closest("[data-action]");
      if (!btn) return;
      const id = Number(btn.dataset.id);
      const action = btn.dataset.action;
      const entry = campaignCache.find((c) => c.id === id);
      if (!entry) return;
      try {
        await requireFactory();
        const c = new ethers.Contract(entry.addr, ABI_C, signer);
        const original = btn.textContent;
        btn.disabled = true;
        btn.innerHTML = '<span class="spin">◌</span> Pending…';
        if (action === "pledge") {
          const amt = $("#pledge-" + id).value;
          if (!amt || Number(amt) <= 0) throw new Error("Pledge must be > 0");
          await send(c.pledge({ value: ethers.parseEther(amt) }), "Pledged");
        } else if (action === "claim") {
          await send(c.claim(), "Claimed");
        } else if (action === "refund") {
          await send(c.refund(), "Refunded");
        }
        btn.disabled = false;
        btn.textContent = original;
      } catch (err) {
        btn.disabled = false;
        btn.textContent = btn.dataset.orig || btn.textContent;
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    // admin
    $("#form-set-fee").addEventListener("submit", async (e) => {
      e.preventDefault();
      await requireFactory();
      const bps = $("#fee-bps").value;
      if (bps === "" || Number(bps) < 0 || Number(bps) > 1000) return toast("Fee must be 0–1000 bps", "error");
      await send(factoryRW.setFeeBps(bps), "Fee updated");
    });
    $("#form-withdraw-fees").addEventListener("submit", async (e) => {
      e.preventDefault();
      await requireFactory();
      const to = $("#withdraw-to").value.trim();
      if (!ethers.isAddress(to)) return toast("Invalid recipient address", "error");
      await send(factoryRW.withdrawFees(to), "Fees withdrawn");
    });

    // live refresh
    setInterval(() => { if (factoryRO) refreshStats(true); }, 15000);
    setInterval(() => { if (factoryRO) refreshCampaigns(); }, 60000);
  }

  async function requireFactory() {
    if (!factoryRO || !factoryAddress) {
      const e = new Error("Configure the factory address first");
      e.__handled = true;
      toast("Configure the factory address first (Settings or the banner above)", "error");
      throw e;
    }
    if (!signer) {
      const e = new Error("Connect your wallet first");
      e.__handled = true;
      toast("Connect your wallet first", "error");
      throw e;
    }
    if (!factoryRW) factoryRW = new ethers.Contract(factoryAddress, ABI_F, signer);
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
    const addr = $("#set-factory-address").value.trim();
    if (addr && !ethers.isAddress(addr)) return toast("Invalid factory address", "error");
    if (addr) {
      factoryAddress = ethers.getAddress(addr);
      localStorage.setItem(LS_ADDRESS, factoryAddress);
    } else {
      localStorage.removeItem(LS_ADDRESS);
    }
    localStorage.setItem(LS_CHAIN, $("#set-chain").value);
    location.reload();
  }

  function copyAddress() {
    if (!factoryAddress) return;
    navigator.clipboard.writeText(factoryAddress).then(
      () => toast("Address copied to clipboard", "success"),
      () => toast("Copy failed — address: " + factoryAddress, "info", 9000)
    );
  }

  /* ---------------- boot ---------------- */

  document.addEventListener("DOMContentLoaded", init);
})();
