/* ============================================================
   TokenVesting dApp — application logic
   ethers.js v6 (UMD global), no build step.
   ============================================================ */

"use strict";

(function () {
  const $ = (s) => document.querySelector(s);
  const cfg = window.APP_CONFIG || {};
  const ABI_V = window.TOKEN_VESTING_ABI || [];
  const ABI_T = window.IERC20_ABI || [];

  const LS_ADDRESS = "vesting.vestingAddress";
  const LS_CHAIN = "vesting.chainId";

  const RING_C = 578.05; // 2π × 92

  /* ---------------- state ---------------- */
  let ifaceV = null;
  let vestingAddress = localStorage.getItem(LS_ADDRESS) || cfg.vestingAddress || "";
  let chainIdPref = Number(localStorage.getItem(LS_CHAIN) || cfg.defaultChainId);
  let readProvider = null;
  let walletProvider = null;
  let signer = null;
  let account = null;
  let vestingRO = null;
  let vestingRW = null;
  let vestingOwner = null;
  let tokenTok = null;
  let chainId = null;
  let schedule = null; // current account's schedule (or null)
  let vested = 0n;
  let releasable = 0n;
  let tickerInterval = null;

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

  function fmtUnits(bn, dec = 18) {
    try {
      const f = ethers.formatUnits(bn, dec);
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
    if (seconds <= 0) return "0s";
    const d = Math.floor(seconds / 86400);
    const h = Math.floor((seconds % 86400) / 3600);
    const m = Math.floor((seconds % 3600) / 60);
    const s = seconds % 60;
    return (d > 0 ? d + "d " : "") + (h > 0 ? h + "h " : "") + (d === 0 ? m + "m " : "") + (d === 0 && h === 0 ? s + "s" : "");
  }

  function fmtDate(ts) {
    if (!ts || Number(ts) === 0) return "—";
    return new Date(Number(ts) * 1000).toLocaleDateString("en", { month: "short", day: "numeric", year: "2-digit" });
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
      const args = (err.revert.args || []).map((a) => (typeof a === "bigint" ? fmtUnits(a).short : shortAddr(String(a)))).join(", ");
      return err.revert.name + (args ? "(" + args + ")" : "");
    }
    if (err.data && ifaceV) {
      try {
        const e = ifaceV.parseError(err.data);
        if (e) {
          const args = e.args.map((a) => (typeof a === "bigint" ? fmtUnits(a).short : shortAddr(String(a)))).join(", ");
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

  function spawnSands() {
    const box = $("#sands");
    for (let i = 0; i < 14; i++) {
      const s = document.createElement("i");
      s.style.left = Math.random() * 100 + "%";
      s.style.setProperty("--d", 7 + Math.random() * 8 + "s");
      s.style.animationDelay = Math.random() * 8 + "s";
      box.appendChild(s);
    }
  }

  async function init() {
    if (typeof ethers === "undefined") {
      toast("ethers.js failed to load — check your internet connection", "error", 12000);
      return;
    }
    ifaceV = new ethers.Interface(ABI_V);
    spawnSands();

    try {
      const res = await fetch("api/config.php", { cache: "no-store" });
      if (res.ok) {
        const data = await res.json();
        if (data && data.vestingAddress && !localStorage.getItem(LS_ADDRESS)) {
          vestingAddress = data.vestingAddress;
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
    vestingAddress = localStorage.getItem(LS_ADDRESS) || vestingAddress || "";

    readProvider = new ethers.JsonRpcProvider(rpcFor(chainIdPref));
    chainId = chainIdPref;

    if (vestingAddress && ethers.isAddress(vestingAddress)) {
      vestingRO = new ethers.Contract(vestingAddress, ABI_V, readProvider);
    } else {
      vestingRO = null;
    }
    vestingRW = null;

    $("#setup-banner").hidden = !!vestingRO;
    $("#chain-badge").textContent = chainCfg(chainIdPref).name;
    $("#chain-badge").classList.toggle("ok", !!chainCfg(chainIdPref).rpc);
    $("#footer-address").textContent = vestingRO ? shortAddr(vestingAddress) : "not configured";
    const ex = chainCfg(chainIdPref).explorer;
    $("#link-contract").href = vestingRO && ex ? ex + "/address/" + vestingAddress : "#";
    $("#link-contract").style.display = vestingRO && ex ? "" : "none";
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
      vestingRW = null;
      schedule = null;
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
    await refreshSchedule();
    await refreshEvents();
    renderOwner();
    startTicker();
  }

  function renderWalletButton() {
    const btn = $("#btn-connect");
    btn.textContent = account ? shortAddr(account) : "Connect Wallet";
    btn.title = account || "";
  }

  async function refreshSchedule(silent) {
    if (!vestingRO) {
      $("#ring-pct").textContent = "0%";
      $("#ring-count").textContent = "configure contract";
      return;
    }
    try {
      if (!tokenTok) {
        tokenTok = new ethers.Contract(await vestingRO.token(), ABI_T, readProvider);
      }
      vestingOwner = await vestingRO.owner();

      if (!account) {
        schedule = null;
        vested = 0n;
        releasable = 0n;
        renderNoWallet();
        return;
      }

      const s = await vestingRO.schedules(account);
      if (Number(s.totalAmount) === 0) {
        schedule = null;
        vested = 0n;
        releasable = 0n;
        renderNoSchedule();
        return;
      }
      schedule = s;
      vested = await vestingRO.vestedAmount(account);
      releasable = vested - s.claimed;
      renderSchedule();
    } catch (err) {
      console.warn("schedule:", err);
      if (!silent) toast("Could not read the contract — is the address correct on this network?", "error", 9000);
    }
  }

  function renderNoWallet() {
    $("#ring-pct").textContent = "0%";
    $("#ring-fill").style.strokeDashoffset = RING_C;
    $("#ring-count").textContent = "connect wallet";
    ["chip-start", "chip-cliff", "chip-end", "chip-total", "chip-claimed"].forEach((id) => ($("#" + id).textContent = "—"));
    const st = $("#chip-status");
    st.textContent = "—";
    st.className = "";
    $("#release-amount").textContent = "—";
    $("#release-sub").textContent = "connect to see your schedule";
    $("#sched-note").textContent = "connect your wallet to see your schedule";
  }

  function renderNoSchedule() {
    $("#ring-pct").textContent = "0%";
    $("#ring-fill").style.strokeDashoffset = RING_C;
    $("#ring-count").textContent = "no schedule for this wallet";
    ["chip-start", "chip-cliff", "chip-end", "chip-total", "chip-claimed"].forEach((id) => ($("#" + id).textContent = "—"));
    const st = $("#chip-status");
    st.textContent = "none";
    st.className = "muted";
    $("#release-amount").textContent = "0";
    $("#release-sub").textContent = "this wallet has no vesting schedule";
    $("#sched-note").textContent = "this wallet has no schedule — ask the owner to fund one";
  }

  function renderSchedule() {
    const s = schedule;
    const now = Math.floor(Date.now() / 1000);
    const total = s.totalAmount;
    const start = Number(s.start);
    const cliff = Number(s.cliff);
    const end = Number(s.end);
    const revoked = s.revoked;

    // ring
    const pct = total > 0n ? Number((vested * 10000n) / total) / 100 : 0;
    $("#ring-pct").textContent = pct.toFixed(pct < 1 ? 2 : 0) + "%";
    $("#ring-fill").style.strokeDashoffset = (RING_C * (1 - Math.min(pct, 100) / 100)).toFixed(2);

    // countdown
    let cdText;
    if (revoked) cdText = "revoked · accrual frozen";
    else if (now < start) cdText = "starts in " + fmtCountdown(start - now);
    else if (now < cliff) cdText = "cliff in " + fmtCountdown(cliff - now);
    else if (now >= end) cdText = "fully vested 🎉";
    else cdText = "fully vested in " + fmtCountdown(end - now);
    $("#ring-count").textContent = cdText;

    // chips
    $("#chip-start").textContent = fmtDate(start);
    $("#chip-cliff").textContent = fmtDate(cliff);
    $("#chip-end").textContent = fmtDate(end);
    $("#chip-total").textContent = fmtUnits(total).short;
    $("#chip-claimed").textContent = fmtUnits(s.claimed).short;
    const st = $("#chip-status");
    if (revoked) { st.textContent = "revoked"; st.className = "st-revoked"; }
    else if (now < start) { st.textContent = "not started"; st.className = "muted"; }
    else if (now < cliff) { st.textContent = "in cliff"; st.className = "st-cliff"; }
    else if (now >= end) { st.textContent = "finished"; st.className = "st-active"; }
    else { st.textContent = "active"; st.className = "st-active"; }

    // schedule bar
    const dur = Math.max(1, end - start);
    const nowP = Math.min(100, Math.max(0, ((now - start) / dur) * 100));
    const cliffP = Math.min(100, Math.max(0, ((cliff - start) / dur) * 100));
    const vestedP = revoked ? Math.min(100, Math.max(0, ((Math.min(Number(s.revokedAt), now) - start) / dur) * 100)) : nowP;
    const bar = $(".sched-bar");
    bar.style.setProperty("--vested-w", vestedP.toFixed(1) + "%");
    bar.style.setProperty("--now-p", nowP.toFixed(1) + "%");
    bar.style.setProperty("--cliff-p", cliffP.toFixed(1) + "%");
    $("#sched-cliff-label").textContent = "cliff · " + fmtDate(cliff);

    // releasable
    updateReleasableDisplay();
  }

  function updateReleasableDisplay() {
    const f = fmtUnits(releasable);
    $("#release-amount").textContent = f.short;
    $("#release-amount").title = f.full;
    $("#release-sub").textContent = schedule ? "of " + fmtUnits(schedule.totalAmount).short + " VEST total" : "";
  }

  /* live ticker: advance releasable locally at the linear rate between refreshes */
  function startTicker() {
    if (tickerInterval) clearInterval(tickerInterval);
    tickerInterval = setInterval(() => {
      if (!schedule || schedule.revoked) return;
      const now = Math.floor(Date.now() / 1000);
      const cliff = Number(schedule.cliff);
      const end = Number(schedule.end);
      if (now >= cliff && now < end) {
        const rate = (schedule.totalAmount * 1000000000000n) / (BigInt(end - cliff));
        releasable += rate / 1000000000000n; // ~total/(end-cliff) per second
        updateReleasableDisplay();
      }
    }, 1000);
    // re-sync with the chain every 10s
    setInterval(async () => {
      if (!account || !vestingRO) return;
      try {
        vested = await vestingRO.vestedAmount(account);
        releasable = vested - schedule.claimed;
        updateReleasableDisplay();
        const pct = schedule && schedule.totalAmount > 0n ? Number((vested * 10000n) / schedule.totalAmount) / 100 : 0;
        $("#ring-pct").textContent = pct.toFixed(pct < 1 ? 2 : 0) + "%";
        $("#ring-fill").style.strokeDashoffset = (RING_C * (1 - Math.min(pct, 100) / 100)).toFixed(2);
      } catch {}
    }, 10000);
  }

  function renderOwner() {
    const isOwner = account && vestingOwner && account.toLowerCase() === vestingOwner.toLowerCase();
    $("#owner-card").hidden = !isOwner;
  }

  /* ---------------- event feed (horizontal cards) ---------------- */

  async function refreshEvents() {
    const strip = $("#event-strip");
    if (!vestingRO) {
      strip.innerHTML = '<p class="muted center" style="padding:24px 0">Deploy the contract to see activity</p>';
      return;
    }
    try {
      const latest = await readProvider.getBlockNumber();
      const fromBlock = Math.max(0, latest - (cfg.eventLookbackBlocks || 50000));
      const logs = await readProvider.getLogs({ address: vestingAddress, fromBlock, toBlock: latest });
      const decoded = logs
        .map((l) => {
          try {
            return { ...ifaceV.parseLog({ topics: l.topics, data: l.data }), blockNumber: Number(l.blockNumber), index: Number(l.index), tx: l.transactionHash };
          } catch {
            return null;
          }
        })
        .filter(Boolean)
        .sort((a, b) => (b.blockNumber - a.blockNumber) || (b.index - a.index))
        .slice(0, 10);

      if (decoded.length === 0) {
        strip.innerHTML = '<p class="muted center" style="padding:24px 0">No events in the last ' + (cfg.eventLookbackBlocks || 50000) + " blocks</p>";
      } else {
        strip.innerHTML = decoded.map(renderEventCard).join("");
      }
      $("#events-note").textContent = "latest " + decoded.length + " events · scroll →";
    } catch (err) {
      strip.innerHTML = '<p class="muted center" style="padding:24px 0">Could not load events</p>';
      console.warn("events:", err);
    }
  }

  function renderEventCard(ev) {
    let ico, detail, pill = ev.name;
    if (ev.name === "ScheduleCreated") {
      ico = "➕";
      detail = addrLink(ev.args.beneficiary) + " got " + fmtUnits(ev.args.amount).short + " VEST";
    } else if (ev.name === "Claimed") {
      ico = "🏦";
      detail = addrLink(ev.args.beneficiary) + " claimed " + fmtUnits(ev.args.amount).short;
    } else if (ev.name === "ScheduleRevoked") {
      ico = "⛔";
      detail = addrLink(ev.args.beneficiary) + " · " + fmtUnits(ev.args.returnedToOwner).short + " returned to owner";
    } else {
      ico = "📜";
      detail = Object.entries(ev.args).map(([k, v]) => k + ": " + shortAddr(String(v))).join(" · ");
    }
    const tx = explorerLink("/tx/" + ev.tx);
    return (
      '<div class="ev-card" style="animation-delay:' + Math.min(ev.blockNumber % 10 * 40, 360) + 'ms">' +
      '<div class="ev-head">' +
      '<span class="ev-ico">' + ico + '</span>' +
      '<span class="ev-pill ev-' + ev.name + '">' + pill + "</span>" +
      '<span class="ev-block">#' + ev.blockNumber + "</span>" +
      "</div>" +
      '<p class="ev-detail mono">' + detail + "</p>" +
      (tx ? '<a class="ev-tx" href="' + tx + '" target="_blank" rel="noopener">' + shortAddr(ev.tx) + " ↗</a>" : "") +
      "</div>"
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
      vestingAddress = ethers.getAddress(addr);
      localStorage.setItem(LS_ADDRESS, vestingAddress);
      location.reload();
    });

    // claim
    $("#btn-claim").addEventListener("click", async () => {
      try {
        await requireVesting();
        await send(vestingRW.claim(), "Claimed");
      } catch (err) {
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    // owner: create schedule (auto-approve if needed)
    $("#form-create").addEventListener("submit", async (e) => {
      e.preventDefault();
      try {
        await requireVesting();
        const ben = $("#create-beneficiary").value.trim();
        const amt = $("#create-amount").value;
        const cliffDays = $("#create-cliff-days").value;
        const vestDays = $("#create-vest-days").value;
        if (!ethers.isAddress(ben)) return toast("Invalid beneficiary address", "error");
        if (!amt || Number(amt) <= 0) return toast("Amount must be > 0", "error");
        if (!cliffDays || Number(cliffDays) < 1 || !vestDays || Number(vestDays) < 1) return toast("Durations must be ≥ 1 day", "error");

        const tokenAddr = await vestingRO.token();
        const tok = new ethers.Contract(tokenAddr, ABI_T, signer);
        const amount = ethers.parseEther(amt);
        const allowance = await tok.allowance(account, vestingAddress);
        if (allowance < amount) {
          const ap = await tok.approve(vestingAddress, amount);
          toast("⏳ Approve submitted — " + txLink(ap.hash), "info", 12000);
          await ap.wait();
        }
        await send(
          vestingRW.createSchedule(ethers.getAddress(ben), amount, BigInt(Math.floor(Date.now() / 1000)), BigInt(Math.floor(Number(cliffDays) * 86400)), BigInt(Math.floor(Number(vestDays) * 86400))),
          "Schedule created"
        );
      } catch (err) {
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    // owner: revoke
    $("#form-revoke").addEventListener("submit", async (e) => {
      e.preventDefault();
      try {
        await requireVesting();
        const ben = $("#revoke-beneficiary").value.trim();
        if (!ethers.isAddress(ben)) return toast("Invalid beneficiary address", "error");
        if (!confirm("Revoke this schedule? Unvested tokens return to you; the beneficiary keeps what already vested.")) return;
        await send(vestingRW.revokeSchedule(ethers.getAddress(ben)), "Schedule revoked");
        $("#revoke-beneficiary").value = "";
      } catch (err) {
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    // live refresh
    setInterval(() => { if (vestingRO) refreshSchedule(true); }, 15000);
  }

  async function requireVesting() {
    if (!vestingRO || !vestingAddress) {
      const e = new Error("Configure the vesting address first");
      e.__handled = true;
      toast("Configure the vesting address first (Settings or the banner above)", "error");
      throw e;
    }
    if (!signer) {
      const e = new Error("Connect your wallet first");
      e.__handled = true;
      toast("Connect your wallet first", "error");
      throw e;
    }
    if (!vestingRW) vestingRW = new ethers.Contract(vestingAddress, ABI_V, signer);
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
    const addr = $("#set-vesting-address").value.trim();
    if (addr && !ethers.isAddress(addr)) return toast("Invalid vesting address", "error");
    if (addr) {
      vestingAddress = ethers.getAddress(addr);
      localStorage.setItem(LS_ADDRESS, vestingAddress);
    } else {
      localStorage.removeItem(LS_ADDRESS);
    }
    localStorage.setItem(LS_CHAIN, $("#set-chain").value);
    location.reload();
  }

  function copyAddress() {
    if (!vestingAddress) return;
    navigator.clipboard.writeText(vestingAddress).then(
      () => toast("Address copied to clipboard", "success"),
      () => toast("Copy failed — address: " + vestingAddress, "info", 9000)
    );
  }

  /* ---------------- boot ---------------- */

  document.addEventListener("DOMContentLoaded", init);
})();
