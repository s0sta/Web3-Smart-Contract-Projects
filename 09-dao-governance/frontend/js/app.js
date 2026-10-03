/* ============================================================
   Senate DAO dApp — application logic
   ethers.js v6 (UMD global), no build step.
   ============================================================ */

"use strict";

(function () {
  const $ = (s) => document.querySelector(s);
  const cfg = window.APP_CONFIG || {};
  const ABI_G = window.GOVERNOR_ABI || [];
  const ABI_T = window.GOV_TOKEN_ABI || [];

  const LS_ADDRESS = "dao.governorAddress";
  const LS_CHAIN = "dao.chainId";

  const STATES = ["Active", "Succeeded", "Defeated", "Executed", "Canceled"];

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
  let tokenTok = null;
  let chainId = null;
  let proposalCount = 0;
  let descriptions = {}; // id → description (recovered from propose tx calldata)
  let rpcFailures = 0;

  /* ---------------- helpers ---------------- */

  function chainCfg(id) {
    return cfg.chains[id] || { name: "Unknown network", short: "unknown", rpc: null, explorer: null, currency: "ETH" };
  }

  function rpcFor(id) {
    return chainCfg(id).rpc || "https://ethereum-rpc.publicnode.com";
  }

  function fallbackRpc(id) {
    const fallbacks = chainCfg(id).rpcFallbacks || [];
    return fallbacks[rpcFailures % (fallbacks.length || 1)];
  }

  function rebuildReadProvider() {
    const rpc = rpcFailures > 0 ? fallbackRpc(chainId ?? chainIdPref) : rpcFor(chainId ?? chainIdPref);
    readProvider = new ethers.JsonRpcProvider(rpc);
    governorRO = new ethers.Contract(governorAddress, ABI_G, readProvider);
    tokenTok = null;
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
    } catch {
      return { short: "—", full: "—" };
    }
  }

  function fmtCountdown(seconds) {
    if (seconds <= 0) return "voting closed";
    const d = Math.floor(seconds / 86400);
    const h = Math.floor((seconds % 86400) / 3600);
    const m = Math.floor((seconds % 3600) / 60);
    return (d > 0 ? d + "d " : "") + h + "h " + m + "m left";
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
    if (err.data && ifaceG) {
      try {
        const e = ifaceG.parseError(err.data);
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
        if (data && data.governorAddress && !localStorage.getItem(LS_ADDRESS)) {
          governorAddress = data.governorAddress;
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
    } else {
      governorRO = null;
    }
    governorRW = null;

    $("#setup-banner").hidden = !!governorRO;
    $("#chain-badge").textContent = chainCfg(chainIdPref).name;
    $("#chain-badge").classList.toggle("ok", !!chainCfg(chainIdPref).rpc);
    $("#footer-address").textContent = governorRO ? shortAddr(governorAddress) : "not configured";
    const ex = chainCfg(chainIdPref).explorer;
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
      governorRW = null;
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
    await refreshGov();
    await refreshFeed();
    await refreshActivity();
  }

  function renderWalletButton() {
    const btn = $("#btn-connect");
    btn.textContent = account ? shortAddr(account) : "Connect Wallet";
    btn.title = account || "";
  }

  /* the Governor exposes proposals[] but no count getter — derive it from events */
  async function getProposalCount() {
    try {
      const latest = await readProvider.getBlockNumber();
      const fromBlock = Math.max(0, latest - (cfg.eventLookbackBlocks || 50000));
      const logs = await readProvider.getLogs({
        address: governorAddress,
        topics: [ifaceG.getEvent("ProposalCreated").topicHash],
        fromBlock,
        toBlock: latest,
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
    } catch {
      return 0;
    }
  }

  async function refreshGov(silent) {
    if (!governorRO) return;
    try {
      if (!tokenTok) {
        tokenTok = new ethers.Contract(await governorRO.token(), ABI_T, readProvider);
      }
      const count = await getProposalCount();
      const [period, threshold, quorumBps, treasury, myBal] = await Promise.all([
        governorRO.votingPeriod(),
        governorRO.proposalThreshold(),
        governorRO.quorumBps(),
        readProvider.getBalance(governorAddress),
        account ? tokenTok.balanceOf(account) : Promise.resolve(0n),
      ]);
      proposalCount = count;

      $("#gov-period").textContent = (Number(period) / 86400).toFixed(1) + " days";
      $("#gov-quorum").textContent = (Number(quorumBps) / 100).toFixed(1) + "% of supply";
      $("#gov-count").textContent = count.toString();
      $("#gov-treasury").textContent = fmtUnits(treasury).short + " ETH";
      $("#threshold").textContent = fmtUnits(threshold).short + " GOV";

      if (account) {
        const pow = fmtUnits(myBal);
        $("#my-power").textContent = pow.short + " GOV";
        $("#my-power").title = pow.full;
        $("#my-balance").textContent = "balance: " + pow.short + " GOV";
      } else {
        $("#my-power").textContent = "—";
        $("#my-balance").textContent = "balance: connect wallet";
      }
    } catch (err) {
      console.warn("gov:", err);
      const fallbacks = chainCfg(chainId ?? chainIdPref).rpcFallbacks || [];
      if (rpcFailures < fallbacks.length) {
        rpcFailures++;
        rebuildReadProvider();
        await refreshGov(silent);
        return;
      }
      rpcFailures = 0;
      rebuildReadProvider();
      if (!silent) toast("Could not read the governor — " + (err.shortMessage || err.message || ""), "error", 9000);
    }
  }

  async function refreshFeed() {
    const feed = $("#proposal-feed");
    if (!governorRO) {
      feed.innerHTML = '<div class="card center muted">Deploy the governor to see proposals</div>';
      return;
    }
    try {
      $("#feed-note").textContent = proposalCount === 0 ? "no proposals yet" : proposalCount + " on-chain";
      if (proposalCount === 0) {
        feed.innerHTML = '<div class="card center muted">The chamber is empty — the first proposal is yours to make.</div>';
        return;
      }
      await cacheDescriptions();
      const cards = [];
      for (let i = proposalCount - 1; i >= 0; i--) {
        cards.push(await renderBallot(i));
      }
      feed.innerHTML = cards.join("");
    } catch (err) {
      console.warn("feed:", err);
      feed.innerHTML = '<div class="card center muted">Could not load proposals</div>';
    }
  }

  /* recover descriptions from the propose transactions' calldata */
  async function cacheDescriptions() {
    try {
      const latest = await readProvider.getBlockNumber();
      const fromBlock = Math.max(0, latest - (cfg.eventLookbackBlocks || 50000));
      const logs = await readProvider.getLogs({
        address: governorAddress,
        topics: [ifaceG.getEvent("ProposalCreated").topicHash],
        fromBlock,
        toBlock: latest,
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

  async function renderBallot(id) {
    const p = await governorRO.proposals(id);
    const st = STATES[Number(await governorRO.state(id))];
    const quorum = await governorRO.quorum(id);
    const now = Math.floor(Date.now() / 1000);
    const deadline = Number(p.deadline);
    const forV = p.forVotes;
    const againstV = p.againstVotes;
    const totalV = forV + againstV;
    const forPct = totalV > 0n ? Number((forV * 10000n) / totalV) / 100 : 0;
    const againstPct = totalV > 0n ? Number((againstV * 10000n) / totalV) / 100 : 0;
    const desc = descriptions[id] || "Proposal #" + id;
    const isProposer = account && p.proposer.toLowerCase() === account.toLowerCase();
    const myVote = account ? await governorRO.hasVoted(id, account) : false;

    const cd = st === "Active" ? fmtCountdown(deadline - now) : "";
    const quorumMet = forV >= quorum;

    let actions = "";
    if (st === "Active" && account && !myVote) {
      actions =
        '<button class="btn btn-ghost" data-action="vote-for" data-id="' + id + '">👍 For</button>' +
        '<button class="btn btn-ghost" data-action="vote-against" data-id="' + id + '">👎 Against</button>' +
        '<span class="countdown">' + cd + "</span>";
    } else if (st === "Active" && account && myVote) {
      actions = '<span class="countdown">✓ voted · ' + cd + "</span>";
    } else if (st === "Active") {
      actions = '<span class="countdown">' + cd + "</span>";
    } else if (st === "Succeeded") {
      actions = '<button class="btn btn-primary" data-action="execute" data-id="' + id + '">Execute</button>';
    }
    if (st === "Active" && isProposer) {
      actions += '<button class="btn btn-danger" data-action="cancel" data-id="' + id + '">Cancel</button>';
    }

    return (
      '<div class="ballot" style="animation-delay:' + Math.min(id * 70, 350) + 'ms">' +
      (myVote ? '<span class="voted-stamp">voted</span>' : "") +
      '<div class="ballot-top">' +
      '<span class="ballot-id">Proposal #' + id + '</span>' +
      '<span class="seal seal-' + st + '">' + st + "</span>" +
      "</div>" +
      '<p class="ballot-desc">' + desc + "</p>" +
      '<div class="ballot-meta">' +
      '<span>by ' + addrLink(p.proposer) + "</span>" +
      '<span>snapshot #' + p.snapshotBlock.toString() + "</span>" +
      '<span>quorum ' + fmtUnits(quorum).short + " GOV" + (quorumMet ? " ✓" : "") + "</span>" +
      "</div>" +
      '<div class="vote-bars">' +
      '<div class="vbar-row vbar-for"><span class="vbar-label">For</span><span class="vbar-track"><span class="vbar-fill" style="width:' + forPct + '%"></span></span><span class="vbar-val">' + fmtUnits(forV).short + " · " + forPct.toFixed(1) + "%</span></div>" +
      '<div class="vbar-row vbar-against"><span class="vbar-label">Against</span><span class="vbar-track"><span class="vbar-fill" style="width:' + againstPct + '%"></span></span><span class="vbar-val">' + fmtUnits(againstV).short + " · " + againstPct.toFixed(1) + "%</span></div>" +
      "</div>" +
      '<div class="ballot-actions">' + actions + "</div>" +
      "</div>"
    );
  }

  async function refreshActivity() {
    const list = $("#act-list");
    if (!governorRO) {
      list.innerHTML = '<p class="muted">Deploy the governor to see activity</p>';
      return;
    }
    try {
      const latest = await readProvider.getBlockNumber();
      const fromBlock = Math.max(0, latest - (cfg.eventLookbackBlocks || 50000));
      const logs = await readProvider.getLogs({ address: governorAddress, fromBlock, toBlock: latest });
      const decoded = logs
        .map((l) => {
          try {
            return { ...ifaceG.parseLog({ topics: l.topics, data: l.data }), blockNumber: Number(l.blockNumber), index: Number(l.index), tx: l.transactionHash };
          } catch {
            return null;
          }
        })
        .filter(Boolean)
        .sort((a, b) => (b.blockNumber - a.blockNumber) || (b.index - a.index))
        .slice(0, 10);

      if (decoded.length === 0) {
        list.innerHTML = '<p class="muted">No activity in the lookback window</p>';
      } else {
        list.innerHTML = decoded.map(renderAct).join("");
      }
    } catch (err) {
      list.innerHTML = '<p class="muted">Could not load activity</p>';
      console.warn("activity:", err);
    }
  }

  function renderAct(ev) {
    let detail = "";
    if (ev.name === "ProposalCreated") {
      detail = "proposal #" + ev.args.proposalId + " by " + addrLink(ev.args.proposer);
    } else if (ev.name === "VoteCast") {
      detail = addrLink(ev.args.voter) + " voted " + (ev.args.support ? "for ✓" : "against ✗") + " #" + ev.args.proposalId + " · " + fmtUnits(ev.args.weight).short + " GOV";
    } else if (ev.name === "ProposalExecuted") {
      detail = "proposal #" + ev.args.proposalId + " executed ⚖️";
    } else if (ev.name === "ProposalCanceled") {
      detail = "proposal #" + ev.args.proposalId + " canceled";
    } else {
      detail = Object.entries(ev.args).map(([k, v]) => k + ": " + shortAddr(String(v))).join(" · ");
    }
    return (
      '<div class="act-item" style="animation-delay:' + Math.min(ev.blockNumber % 10 * 35, 320) + 'ms">' +
      '<span class="act-tag act-' + ev.name + '">' + ev.name + "</span>" +
      '<span class="act-detail mono">' + detail + "</span>" +
      '<span class="mono muted">#' + ev.blockNumber + "</span>" +
      "</div>"
    );
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

    // delegated ballot actions
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
        if (action === "vote-for") {
          await send(governorRW.vote(id, true), "Vote cast");
        } else if (action === "vote-against") {
          await send(governorRW.vote(id, false), "Vote cast");
        } else if (action === "execute") {
          await send(governorRW.execute(id), "Proposal executed");
        } else if (action === "cancel") {
          await send(governorRW.cancel(id), "Proposal canceled");
        }
        btn.disabled = false;
        btn.textContent = original;
      } catch (err) {
        btn.disabled = false;
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    // create proposal
    $("#form-propose").addEventListener("submit", async (e) => {
      e.preventDefault();
      try {
        await requireGovernor();
        const target = $("#p-target").value.trim();
        const value = $("#p-value").value || "0";
        let calldata = $("#p-calldata").value.trim() || "0x";
        const desc = $("#p-desc").value.trim();
        if (!ethers.isAddress(target)) return toast("Invalid target address", "error");
        if (!desc) return toast("Add a description", "error");
        if (!/^0x[0-9a-fA-F]*$/.test(calldata)) return toast("Calldata must be hex (0x…)", "error");

        await send(
          governorRW.propose([ethers.getAddress(target)], [ethers.parseEther(value)], [calldata], desc),
          "Proposal created"
        );
        $("#p-target").value = "";
        $("#p-value").value = "";
        $("#p-calldata").value = "";
        $("#p-desc").value = "";
      } catch (err) {
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    // live refresh
    setInterval(() => { if (governorRO) refreshFeed(); }, 30000);
  }

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

  /* ---------------- settings ---------------- */

  function saveSettings() {
    const addr = $("#set-governor-address").value.trim();
    if (addr && !ethers.isAddress(addr)) return toast("Invalid governor address", "error");
    if (addr) {
      governorAddress = ethers.getAddress(addr);
      localStorage.setItem(LS_ADDRESS, governorAddress);
    } else {
      localStorage.removeItem(LS_ADDRESS);
    }
    localStorage.setItem(LS_CHAIN, $("#set-chain").value);
    location.reload();
  }

  /* ---------------- boot ---------------- */

  document.addEventListener("DOMContentLoaded", init);
})();
