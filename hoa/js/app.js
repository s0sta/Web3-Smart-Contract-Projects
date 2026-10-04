/* ============================================================
   JOP Owners Association dApp — application logic
   ethers.js v6 (UMD global), no build step.
   ============================================================ */

"use strict";

(function () {
  const $ = (s) => document.querySelector(s);
  const cfg = window.APP_CONFIG || {};
  const ABI_G = window.JOP_GOVERNOR_ABI || [];
  const ABI_R = window.JOP_REGISTRY_ABI || [];
  const ABI_T = window.JOP_TREASURY_ABI || [];
  const ABI_S = window.JOP_STABLE_ABI || [];

  const LS_ADDRESS = "hoa.governorAddress";
  const LS_CHAIN = "hoa.chainId";

  const STATE_NAMES = ["Review", "Active", "Timelock", "Succeeded", "Executed", "Defeated", "Canceled", "Vetoed"];
  const TYPE_NAMES = ["Budget", "ChargeRate", "Contract", "Rules", "Election", "Payment", "Emergency"];

  /* ---------------- state ---------------- */
  let ifaceG = null;
  let governorAddress = localStorage.getItem(LS_ADDRESS) || cfg.governorAddress || "";
  let chainIdPref = Number(localStorage.getItem(LS_CHAIN) || cfg.defaultChainId);
  let readProvider = null;
  let walletProvider = null;
  let signer = null;
  let account = null;
  let governorRO = null;
  let governorRW = null;
  let registryRO = null;
  let treasuryRO = null;
  let stableTok = null;
  let chainId = null;
  let proposalCount = 0;
  let unitCount = 0;
  let myUnitIds = [];
  let descriptions = {};
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
    governorRO = new ethers.Contract(governorAddress, ABI_G, readProvider);
    registryRO = null; treasuryRO = null; stableTok = null;
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
        n >= 1 ? new Intl.NumberFormat("en", { maximumFractionDigits: 2 }).format(n) :
        new Intl.NumberFormat("en", { maximumFractionDigits: 4 }).format(n);
      return { short: compact, full: f };
    } catch { return { short: "—", full: "—" }; }
  }
  function fmtCountdown(seconds) {
    if (seconds <= 0) return "closed";
    const d = Math.floor(seconds / 86400);
    const h = Math.floor((seconds % 86400) / 3600);
    const m = Math.floor((seconds % 3600) / 60);
    return (d > 0 ? d + "d " : "") + h + "h " + m + "m left";
  }
  function fmtDate(ts) {
    if (!ts || Number(ts) === 0) return "—";
    return new Date(Number(ts) * 1000).toLocaleDateString("en", { month: "short", day: "numeric" });
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
    setTimeout(() => { el.classList.add("out"); setTimeout(() => el.remove(), 300); }, ttl);
  }

  function decodeError(err) {
    if (!err) return "Unknown error";
    if (err.revert && err.revert.name) return err.revert.name;
    if (err.data && ifaceG) {
      try { const e = ifaceG.parseError(err.data); if (e) return e.name; } catch {}
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
    ifaceG = new ethers.Interface(ABI_G);

    try {
      const res = await fetch("api/config.php", { cache: "no-store" });
      if (res.ok) {
        const data = await res.json();
        if (data && data.governorAddress && !localStorage.getItem(LS_ADDRESS)) governorAddress = data.governorAddress;
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
    governorAddress = localStorage.getItem(LS_ADDRESS) || governorAddress || "";

    readProvider = new ethers.JsonRpcProvider(rpcFor(chainIdPref));
    chainId = chainIdPref;

    if (governorAddress && ethers.isAddress(governorAddress)) {
      governorRO = new ethers.Contract(governorAddress, ABI_G, readProvider);
    } else governorRO = null;
    governorRW = null;

    $("#setup-banner").hidden = !!governorRO;
    $("#chain-badge").textContent = chainCfg(chainIdPref).name;
    $("#chain-badge").classList.toggle("ok", !!chainCfg(chainIdPref).rpc);
    $("#footer-address").textContent = governorRO ? shortAddr(governorAddress) : "not configured";
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
      account = null; signer = null; governorRW = null;
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
    await refreshAssociation();
    await refreshFeed();
    await refreshUnits();
  }

  function renderWalletButton() {
    const btn = $("#btn-connect");
    btn.textContent = account ? shortAddr(account) : "Connect Wallet";
    btn.title = account || "";
  }

  async function refreshAssociation(silent) {
    if (!governorRO) return;
    try {
      if (!registryRO) {
        registryRO = new ethers.Contract(await governorRO.registry(), ABI_R, readProvider);
        treasuryRO = new ethers.Contract(await governorRO.treasury(), ABI_T, readProvider);
        stableTok = new ethers.Contract(await registryRO.chargeToken(), ABI_S, readProvider);
      }

      const [threshold, units, area, rate, tresBal, reserve, paid, seats] = await Promise.all([
        governorRO.proposalThresholdSqm(),
        registryRO.unitCount(),
        registryRO.totalAreaSqm(),
        registryRO.annualChargePerSqm(),
        stableTok.balanceOf(await governorRO.treasury()),
        treasuryRO.reserveBps(),
        treasuryRO.totalPaidOut(),
        Promise.all([0, 1, 2, 3, 4].map((i) => governorRO.boardSeats(i))),
      ]);
      unitCount = Number(units);

      $("#threshold").textContent = fmtUnits(threshold).short + " sqm";
      $("#gov-treasury").textContent = fmtUnits(tresBal).short + " AED-S";
      $("#gov-reserve").textContent = (Number(reserve) / 100).toFixed(1) + "%";
      $("#gov-paid").textContent = fmtUnits(paid).short + " AED-S";
      $("#gov-charge").textContent = fmtUnits(rate).short + " / sqm";
      $("#gov-units").textContent = units.toString() + " · " + area.toString() + " sqm";
      $("#board-list").textContent = "board: " + seats.filter((s) => s !== ethers.ZeroAddress).map(shortAddr).join(" · ");

      if (account) {
        const power = await governorRO.votingPower(account);
        const pw = $("#my-power");
        pw.textContent = fmtUnits(power).short + " sqm";
        pw.classList.remove("bump"); void pw.offsetWidth; pw.classList.add("bump");

        const del = await governorRO.delegatee(account);
        const exp = await governorRO.delegationExpiry(account);
        const active = await governorRO.delegationActive(account);
        $("#my-delegation").textContent = active
          ? "proxied to " + shortAddr(del) + " until " + fmtDate(exp)
          : "no active proxy";

        const roles = [];
        if (await governorRO.hasRole(governorRO.BOARD_MEMBER_ROLE(), account)) roles.push("board");
        if (await governorRO.hasRole(governorRO.COMPLIANCE_ROLE(), account)) roles.push("compliance");
        if (await governorRO.hasRole(governorRO.GUARDIAN_ROLE(), account)) roles.push("guardian");
        $("#my-roles").textContent = "your roles: " + (roles.length ? roles.join(" · ") : "owner");
      } else {
        $("#my-power").textContent = "—";
        $("#my-delegation").textContent = "no active proxy";
        $("#my-roles").textContent = "your roles: —";
      }
    } catch (err) {
      console.warn("association:", err);
      const fallbacks = chainCfg(chainId ?? chainIdPref).rpcFallbacks || [];
      if (rpcFailures < fallbacks.length) {
        rpcFailures++;
        rebuildReadProvider();
        await refreshAssociation(silent);
        return;
      }
      rpcFailures = 0;
      rebuildReadProvider();
      if (!silent) toast("Could not read the association — " + (err.shortMessage || err.message || ""), "error", 9000);
    }
  }

  async function getProposalCount() {
    try {
      const latest = await readProvider.getBlockNumber();
      const fromBlock = Math.max(0, latest - (cfg.eventLookbackBlocks || 50000));
      const logs = await readProvider.getLogs({
        address: governorAddress,
        topics: [ifaceG.getEvent("ProposalCreated").topicHash],
        fromBlock, toBlock: latest,
      });
      let max = -1;
      for (const l of logs) {
        try {
          const parsed = ifaceG.parseLog({ topics: l.topics, data: l.data });
          const id = Number(parsed.args.proposalId);
          if (id > max) max = id;
        } catch {}
      }
      return max + 1;
    } catch { return 0; }
  }

  async function cacheDescriptions() {
    try {
      const latest = await readProvider.getBlockNumber();
      const fromBlock = Math.max(0, latest - (cfg.eventLookbackBlocks || 50000));
      const logs = await readProvider.getLogs({
        address: governorAddress,
        topics: [ifaceG.getEvent("ProposalCreated").topicHash],
        fromBlock, toBlock: latest,
      });
      for (const l of logs) {
        try {
          const parsed = ifaceG.parseLog({ topics: l.topics, data: l.data });
          const id = Number(parsed.args.proposalId);
          if (descriptions[id] !== undefined) continue;
          const tx = await readProvider.getTransaction(l.transactionHash);
          if (tx) {
            const decoded = ifaceG.parseTransaction({ data: tx.data, value: tx.value });
            descriptions[id] = decoded.args.description || "Proposal #" + id;
          }
        } catch {}
      }
    } catch {}
  }

  async function refreshFeed() {
    const feed = $("#proposal-feed");
    if (!governorRO) {
      feed.innerHTML = '<div class="card center muted">Deploy the governor to see proposals</div>';
      return;
    }
    try {
      proposalCount = await getProposalCount();
      $("#feed-note").textContent = proposalCount === 0 ? "no proposals yet" : proposalCount + " on-chain";
      if (proposalCount === 0) {
        feed.innerHTML = '<div class="card center muted">The chamber is empty — submit the first proposal.</div>';
        return;
      }
      await cacheDescriptions();
      const cards = [];
      for (let i = proposalCount - 1; i >= 0; i--) cards.push(await renderBallot(i));
      feed.innerHTML = cards.join("");
    } catch (err) {
      console.warn("feed:", err);
      feed.innerHTML = '<div class="card center muted">Could not load proposals</div>';
    }
  }

  async function renderBallot(id) {
    const p = await governorRO.proposals(id);
    const st = Number(await governorRO.state(id));
    const quorum = await governorRO.quorum(id);
    const now = Math.floor(Date.now() / 1000);
    const forV = p.forVotes;
    const againstV = p.againstVotes;
    const totalV = forV + againstV;
    const forPct = totalV > 0n ? Number((forV * 10000n) / totalV) / 100 : 0;
    const againstPct = totalV > 0n ? Number((againstV * 10000n) / totalV) / 100 : 0;
    const desc = descriptions[id] || "Proposal #" + id;
    const isBoard = account ? await governorRO.hasRole(governorRO.BOARD_MEMBER_ROLE(), account) : false;
    const isCompliance = account ? await governorRO.hasRole(governorRO.COMPLIANCE_ROLE(), account) : false;
    const isProposer = account && p.proposer.toLowerCase() === account.toLowerCase();
    const myVote = account ? await governorRO.hasVoted(id, account) : false;

    let actions = "";
    if (st === 0 && isBoard) actions += '<button class="btn btn-ghost btn-sm" data-action="fasttrack" data-id="' + id + '">⚡ Fast-track</button>';
    if (st === 0 && isCompliance) actions += '<button class="btn btn-danger btn-sm" data-action="veto" data-id="' + id + '">Veto</button>';
    if (st === 1 && account && !myVote) {
      actions += '<button class="btn btn-ghost btn-sm" data-action="vote-for" data-id="' + id + '">👍 For</button>' +
                 '<button class="btn btn-ghost btn-sm" data-action="vote-against" data-id="' + id + '">👎 Against</button>';
    }
    if ((st === 0 || st === 1) && (isProposer || isBoard)) actions += '<button class="btn btn-danger btn-sm" data-action="cancel" data-id="' + id + '">Cancel</button>';
    if ((st === 2 || st === 3) && !p.executed) actions += '<button class="btn btn-primary btn-sm" data-action="execute" data-id="' + id + '">Execute</button>';
    if (st === 1) actions += '<span class="countdown">' + fmtCountdown(Number(p.voteEnd) - now) + "</span>";
    if (myVote) actions += '<span class="countdown" style="color:#4ade80">✓ you voted</span>';

    return (
      '<div class="ballot" style="animation-delay:' + Math.min(id * 70, 350) + 'ms">' +
      '<div class="ballot-top">' +
      '<span class="ballot-id">Proposal #' + id + '</span>' +
      '<span class="seal seal-' + st + '">' + STATE_NAMES[st] + "</span>" +
      '<span class="mono muted" style="margin-left:auto">' + TYPE_NAMES[Number(p.pType)] + "</span>" +
      "</div>" +
      '<p class="ballot-desc">' + desc + "</p>" +
      '<div class="ballot-meta">' +
      '<span>by ' + addrLink(p.proposer) + "</span>" +
      '<span>vote ' + fmtDate(p.voteStart) + " → " + fmtDate(p.voteEnd) + "</span>" +
      '<span>quorum ' + fmtUnits(quorum).short + " sqm" + (forV >= quorum ? " ✓" : "") + "</span>" +
      "</div>" +
      '<div class="vote-bars">' +
      '<div class="vbar-row vbar-for"><span class="vbar-label">For</span><span class="vbar-track"><span class="vbar-fill" style="width:' + forPct + '%"></span></span><span class="vbar-val">' + fmtUnits(forV).short + " sqm · " + forPct.toFixed(1) + "%</span></div>" +
      '<div class="vbar-row vbar-against"><span class="vbar-label">Against</span><span class="vbar-track"><span class="vbar-fill" style="width:' + againstPct + '%"></span></span><span class="vbar-val">' + fmtUnits(againstV).short + " sqm · " + againstPct.toFixed(1) + "%</span></div>" +
      "</div>" +
      '<div class="ballot-actions">' + actions + "</div>" +
      "</div>"
    );
  }

  async function refreshUnits() {
    const card = $("#units-card");
    if (!registryRO) {
      card.innerHTML = '<p class="muted">Deploy the association to see the register</p>';
      return;
    }
    try {
      let rows = "";
      myUnitIds = [];
      for (let i = 0; i < unitCount; i++) {
        const u = await registryRO.units(i);
        const mine = account && u.owner.toLowerCase() === account.toLowerCase();
        if (mine) myUnitIds.push(i);
        rows +=
          "<tr><td class='mono'>#" + i + "</td>" +
          "<td class='mono'>" + u.areaSqm.toString() + "</td>" +
          "<td>" + addrLink(u.owner) + (mine ? ' <span class="unit-you">you</span>' : "") + "</td>" +
          '<td class="mono">' + fmtUnits(u.chargeDebt).short + "</td></tr>";
      }
      card.innerHTML =
        '<table class="unit-table"><thead><tr><th>Unit</th><th>Area (sqm)</th><th>Owner</th><th>Charge debt (AED-S)</th></tr></thead>' +
        "<tbody>" + rows + "</tbody></table>";

      const myDebt = account ? await myChargeDebt() : 0n;
      $("#gov-myledger").textContent = account ? fmtUnits(myDebt).short + " AED-S · units " + myUnitIds.join(",") : "—";
    } catch (err) {
      console.warn("units:", err);
      card.innerHTML = '<p class="muted">Could not load the register</p>';
    }
  }

  async function myChargeDebt() {
    let total = 0n;
    for (const id of myUnitIds) {
      const u = await registryRO.units(id);
      total += u.chargeDebt;
    }
    return total;
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
      governorAddress = ethers.getAddress(addr);
      localStorage.setItem(LS_ADDRESS, governorAddress);
      location.reload();
    });

    $("#proposal-feed").addEventListener("click", async (e) => {
      const btn = e.target.closest("[data-action]");
      if (!btn) return;
      const id = Number(btn.dataset.id);
      const action = btn.dataset.action;
      try {
        await requireGovernor();
        const original = btn.textContent;
        btn.disabled = true;
        btn.innerHTML = '<span class="spin">◌</span>…';
        if (action === "vote-for") await send(governorRW.vote(id, true), "Vote cast");
        else if (action === "vote-against") await send(governorRW.vote(id, false), "Vote cast");
        else if (action === "execute") await send(governorRW.execute(id), "Proposal executed");
        else if (action === "cancel") await send(governorRW.cancel(id), "Proposal canceled");
        else if (action === "fasttrack") await send(governorRW.fastTrack(id), "Fast-tracked");
        else if (action === "veto") {
          const note = prompt("Veto note (recorded on-chain):") || "";
          await send(governorRW.veto(id, note), "Proposal vetoed");
        }
        btn.disabled = false;
        btn.textContent = original;
      } catch (err) {
        btn.disabled = false;
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    $("#form-propose").addEventListener("submit", async (e) => {
      e.preventDefault();
      try {
        await requireGovernor();
        const pType = $("#p-type").value;
        const target = $("#p-target").value.trim();
        const value = $("#p-value").value || "0";
        let calldata = $("#p-calldata").value.trim() || "0x";
        const desc = $("#p-desc").value.trim();
        if (!ethers.isAddress(target)) return toast("Invalid target address", "error");
        if (!desc) return toast("Add a description", "error");
        if (!/^0x[0-9a-fA-F]*$/.test(calldata)) return toast("Calldata must be hex (0x…)", "error");
        await send(
          governorRW.propose(pType, [ethers.getAddress(target)], [ethers.parseEther(value)], [calldata], desc),
          "Proposal created"
        );
        $("#p-target").value = ""; $("#p-value").value = ""; $("#p-calldata").value = ""; $("#p-desc").value = "";
      } catch (err) {
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    $("#form-delegate").addEventListener("submit", async (e) => {
      e.preventDefault();
      try {
        await requireGovernor();
        const to = $("#delegate-to").value.trim();
        const days = $("#delegate-days").value;
        if (!ethers.isAddress(to)) return toast("Invalid delegate address", "error");
        if (!days || Number(days) < 1) return toast("Days must be ≥ 1", "error");
        await send(governorRW.delegate(ethers.getAddress(to), BigInt(Math.floor(Date.now() / 1000 + Number(days) * 86400))), "Delegated");
        $("#delegate-to").value = ""; $("#delegate-days").value = "";
      } catch (err) {
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    $("#btn-revoke-delegation").addEventListener("click", async () => {
      try {
        await requireGovernor();
        await send(governorRW.revokeDelegation(), "Proxy revoked");
      } catch (err) {
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    $("#form-pay").addEventListener("submit", async (e) => {
      e.preventDefault();
      try {
        await requireGovernor();
        const amt = $("#pay-amount").value;
        if (!amt || Number(amt) <= 0) return toast("Amount must be > 0", "error");
        if (myUnitIds.length === 0) return toast("You own no registered units", "error");
        const amount = ethers.parseEther(amt);
        const stableAddr = await registryRO.chargeToken();
        const tok = new ethers.Contract(stableAddr, ABI_S, signer);
        const registryAddr = await registryRO.getAddress();
        const allowance = await tok.allowance(account, registryAddr);
        if (allowance < amount) {
          const ap = await tok.approve(registryAddr, amount);
          toast("⏳ Approve submitted — " + txLink(ap.hash), "info", 12000);
          await ap.wait();
        }
        await send(payCharges(amount), "Charges paid");
        $("#pay-amount").value = "";
      } catch (err) {
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    setInterval(() => { if (governorRO) refreshFeed(); }, 30000);
  }

  async function payCharges(amount) {
    if (!registryRW) registryRW = new ethers.Contract(await governorRO.registry(), ABI_R, signer);
    // pay the first unit with debt; units are typically billed together in the demo
    return registryRW.payServiceCharge(myUnitIds[0], amount);
  }

  let registryRW = null;

  async function requireGovernor() {
    if (!governorRO || !governorAddress) {
      const e = new Error("Configure the governor address first");
      e.__handled = true;
      toast("Configure the governor address first (Settings or the banner above)", "error");
      throw e;
    }
    if (!signer) {
      const e = new Error("Connect your wallet first");
      e.__handled = true;
      toast("Connect your wallet first", "error");
      throw e;
    }
    if (!governorRW) governorRW = new ethers.Contract(governorAddress, ABI_G, signer);
  }

  async function send(txPromise, label) {
    const tx = await txPromise;
    toast("⏳ " + label + " submitted — " + txLink(tx.hash), "info", 12000);
    await tx.wait();
    toast("✅ " + label + " confirmed — " + txLink(tx.hash), "success", 9000);
    await refreshAll();
  }

  function saveSettings() {
    const addr = $("#set-governor-address").value.trim();
    if (addr && !ethers.isAddress(addr)) return toast("Invalid governor address", "error");
    if (addr) {
      governorAddress = ethers.getAddress(addr);
      localStorage.setItem(LS_ADDRESS, governorAddress);
    } else localStorage.removeItem(LS_ADDRESS);
    localStorage.setItem(LS_CHAIN, $("#set-chain").value);
    location.reload();
  }

  document.addEventListener("DOMContentLoaded", init);
})();
