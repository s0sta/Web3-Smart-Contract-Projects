/* ============================================================
   Waqf Endowment dApp — application logic
   ethers.js v6 (UMD global), no build step.
   ============================================================ */

"use strict";

(function () {
  const $ = (s) => document.querySelector(s);
  const cfg = window.APP_CONFIG || {};
  const ABI_V = window.WAQF_VAULT_ABI || [];
  const ABI_R = window.WAQF_REGISTRY_ABI || [];
  const ABI_G = window.WAQF_GOVERNOR_ABI || [];
  const ABI_S = window.WAQF_STABLE_ABI || [];

  const LS_ADDRESS = "waqf.vaultAddress";
  const LS_CHAIN = "waqf.chainId";

  /* ---------------- state ---------------- */
  let ifaceG = null;
  let vaultAddress = localStorage.getItem(LS_ADDRESS) || cfg.vaultAddress || "";
  let chainIdPref = Number(localStorage.getItem(LS_CHAIN) || cfg.defaultChainId);
  let readProvider = null;
  let walletProvider = null;
  let signer = null;
  let account = null;
  let vaultRO = null;
  let vaultRW = null;
  let registryRO = null;
  let registryRW = null;
  let governorRO = null;
  let governorRW = null;
  let stableTok = null;
  let chainId = null;
  let rpcFailures = 0;
  let descriptions = {};

  const STATE_NAMES = ["Confirmation", "Voting", "Timelock", "Succeeded", "Executed", "Defeated", "Canceled"];
  const TYPE_NAMES = ["AdjustWeight", "AddBeneficiary", "RemoveBeneficiary", "OperationalSpend", "Rules"];

  /* ---------------- helpers ---------------- */

  function chainCfg(id) {
    return cfg.chains[id] || { name: "Unknown network", short: "unknown", rpc: null, explorer: null, currency: "ETH" };
  }
  function rpcFor(id) { return chainCfg(id).rpc || "https://ethereum-rpc.publicnode.com"; }
  function fallbackRpc(id) { return (chainCfg(id).rpcFallbacks || [])[rpcFailures % (chainCfg(id).rpcFallbacks?.length || 1)]; }
  function rebuildReadProvider() {
    const rpc = rpcFailures > 0 ? fallbackRpc(chainId ?? chainIdPref) : rpcFor(chainId ?? chainIdPref);
    readProvider = new ethers.JsonRpcProvider(rpc);
    vaultRO = new ethers.Contract(vaultAddress, ABI_V, readProvider);
    registryRO = null; governorRO = null; stableTok = null;
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
        if (data && data.vaultAddress && !localStorage.getItem(LS_ADDRESS)) vaultAddress = data.vaultAddress;
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
    vaultAddress = localStorage.getItem(LS_ADDRESS) || vaultAddress || "";

    readProvider = new ethers.JsonRpcProvider(rpcFor(chainIdPref));
    chainId = chainIdPref;

    if (vaultAddress && ethers.isAddress(vaultAddress)) {
      vaultRO = new ethers.Contract(vaultAddress, ABI_V, readProvider);
    } else vaultRO = null;
    vaultRW = null; registryRO = null; governorRO = null;

    $("#setup-banner").hidden = !!vaultRO;
    $("#chain-badge").textContent = chainCfg(chainIdPref).name;
    $("#chain-badge").classList.toggle("ok", !!chainCfg(chainIdPref).rpc);
    $("#footer-address").textContent = vaultRO ? shortAddr(vaultAddress) : "not configured";
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
      account = null; signer = null; vaultRW = null; governorRW = null;
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
    await refreshVault();
    await refreshBeneficiaries();
    await refreshProposals();
  }

  function renderWalletButton() {
    const btn = $("#btn-connect");
    btn.textContent = account ? shortAddr(account) : "Connect Wallet";
    btn.title = account || "";
  }

  async function refreshVault(silent) {
    if (!vaultRO) return;
    try {
      if (!stableTok) stableTok = new ethers.Contract(await vaultRO.endowedToken(), ABI_S, readProvider);

      const [corpus, pool, distributed, operational, frozen] = await Promise.all([
        vaultRO.totalCorpus(),
        vaultRO.distributablePool(),
        vaultRO.totalDistributed(),
        vaultRO.operationalFund(),
        vaultRO.frozen(),
      ]);
      $("#strip-corpus").textContent = fmtUnits(corpus) + " AED-S";
      $("#strip-pool").textContent = fmtUnits(pool) + " AED-S";
      $("#strip-distributed").textContent = fmtUnits(distributed) + " AED-S";
      $("#strip-operational").textContent = fmtUnits(operational) + " AED-S";
      $("#strip-status").innerHTML = frozen
        ? '<span style="color:#b3402f">FROZEN</span>'
        : '<span style="color:#1d9d63">ACTIVE</span>';

      if (account) {
        const contrib = await vaultRO.contributions(account);
        $("#kpi-contribution").textContent = fmtUnits(contrib) + " AED-S";
        $("#kpi-power").textContent = fmtUnits(contrib) + " votes";
      }
      if (cfg.governorAddress) {
        const threshold = await governorRO2().then((g) => g.proposalThreshold());
        $("#kpi-threshold").textContent = fmtUnits(threshold) + " AED-S";
      }
    } catch (err) {
      console.warn("vault:", err);
      const fallbacks = chainCfg(chainId ?? chainIdPref).rpcFallbacks || [];
      if (rpcFailures < fallbacks.length) {
        rpcFailures++;
        rebuildReadProvider();
        await refreshVault(silent);
        return;
      }
      rpcFailures = 0;
      rebuildReadProvider();
      if (!silent) toast("Could not read the waqf — " + (err.shortMessage || err.message || ""), "error", 9000);
    }
  }

  async function governorRO2() {
    if (!governorRO) governorRO = new ethers.Contract(cfg.governorAddress, ABI_G, readProvider);
    return governorRO;
  }

  async function refreshBeneficiaries() {
    const list = $("#beneficiary-list");
    if (!vaultRO || !cfg.registryAddress) return;
    try {
      if (!registryRO) registryRO = new ethers.Contract(cfg.registryAddress, ABI_R, readProvider);
      const count = await registryRO.beneficiaryCount();
      let rows = "";
      let total = 0n;
      for (let i = 0; i < count; i++) {
        const b = await registryRO.beneficiaries(i);
        if (b.active) total += b.weightBps;
        rows +=
          '<div class="bene-row' + (b.active ? "" : " bene-inactive") + '">' +
          '<span class="mono">#' + i + "</span>" +
          '<span>' + shortAddr(b.account) + "</span>" +
          '<span class="bene-weight">' + (Number(b.weightBps) / 100).toFixed(1) + "%</span>" +
          "</div>" +
          '<div class="weight-bar"><span style="width:' + (Number(b.weightBps) / 100) + '%"></span></div>';
      }
      list.innerHTML = rows || '<p class="muted">no beneficiaries yet</p>';
      $("#beneficiary-total").textContent = "total active weight: " + (Number(total) / 100).toFixed(1) + "%";
    } catch (err) {
      list.innerHTML = '<p class="muted">Could not load beneficiaries</p>';
    }
  }

  async function getProposalCount() {
    try {
      const latest = await readProvider.getBlockNumber();
      const fromBlock = Math.max(0, latest - (cfg.eventLookbackBlocks || 50000));
      const logs = await readProvider.getLogs({
        address: cfg.governorAddress,
        topics: [ifaceG.getEvent("ProposalCreated").topicHash],
        fromBlock, toBlock: latest,
      });
      let max = -1;
      for (const l of logs) {
        try {
          const parsed = ifaceG.parseLog({ topics: l.topics, data: l.data });
          if (Number(parsed.args.proposalId) > max) max = Number(parsed.args.proposalId);
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
        address: cfg.governorAddress,
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

  async function refreshProposals() {
    const list = $("#proposal-list");
    if (!vaultRO || !cfg.governorAddress) {
      list.innerHTML = '<p class="muted">Deploy the governor to see proposals</p>';
      return;
    }
    try {
      await governorRO2();
      const count = await getProposalCount();
      $("#gov-note").textContent = count === 0 ? "no proposals yet" : count + " on-chain";
      if (count === 0) {
        list.innerHTML = '<p class="muted">No proposals — the board awaits the first motion.</p>';
        return;
      }
      await cacheDescriptions();
      const cards = [];
      for (let i = count - 1; i >= 0; i--) cards.push(await renderProp(i));
      list.innerHTML = cards.join("");
    } catch (err) {
      list.innerHTML = '<p class="muted">Could not load proposals</p>';
    }
  }

  async function renderProp(id) {
    const p = await governorRO.proposals(id);
    const st = Number(await governorRO.state(id));
    const quorum = await governorRO.quorum(id);
    const desc = descriptions[id] || "Proposal #" + id;
    const isNazir = account ? await governorRO.hasRole(governorRO.NAZIR_ROLE(), account) : false;
    const isProposer = account && p.proposer.toLowerCase() === account.toLowerCase();
    const myVote = account ? await governorRO.hasVoted(id, account) : false;

    let actions = "";
    if (st === 0 && isNazir) actions += '<button class="btn btn-ghost btn-sm" data-action="confirm" data-id="' + id + '">✓ Confirm</button>';
    if (st === 1 && account && !myVote) {
      actions += '<button class="btn btn-ghost btn-sm" data-action="vote-for" data-id="' + id + '">For</button>' +
                 '<button class="btn btn-ghost btn-sm" data-action="vote-against" data-id="' + id + '">Against</button>';
    }
    if ((st === 0 || st === 1 || st === 2) && (isProposer || isNazir)) actions += '<button class="btn btn-danger btn-sm" data-action="cancel" data-id="' + id + '">Cancel</button>';
    if (st === 3 && !p.executed) actions += '<button class="btn btn-primary btn-sm" data-action="execute" data-id="' + id + '">Execute</button>';
    if (myVote) actions += '<span class="muted small">✓ voted</span>';

    return (
      '<div class="prop">' +
      '<div class="prop-top">' +
      '<span class="prop-id">#' + id + "</span>" +
      '<span class="seal seal-' + st + '">' + STATE_NAMES[st] + "</span>" +
      '<span class="mono muted" style="margin-left:auto">' + TYPE_NAMES[Number(p.pType)] + "</span>" +
      "</div>" +
      '<p class="prop-desc">' + desc + "</p>" +
      '<div class="prop-meta">' +
      '<span>by ' + shortAddr(p.proposer) + "</span>" +
      '<span>for ' + fmtUnits(p.forVotes).short + " · against " + fmtUnits(p.againstVotes).short + "</span>" +
      '<span>quorum ' + fmtUnits(quorum).short + "</span>" +
      '<span>confirmations ' + p.confirmations.toString() + "/2</span>" +
      "</div>" +
      '<div class="prop-actions">' + actions + "</div>" +
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
      vaultAddress = ethers.getAddress(addr);
      localStorage.setItem(LS_ADDRESS, vaultAddress);
      location.reload();
    });

    $("#btn-endow").addEventListener("click", async () => {
      try {
        await requireSigner();
        const amt = $("#endow-amount").value;
        if (!amt || Number(amt) <= 0) return toast("Amount must be > 0", "error");
        const amount = ethers.parseEther(amt);
        const allowance = await stableTok.allowance(account, vaultAddress);
        if (allowance < amount) {
          const ap = await stableTok.connect(signer).approve(vaultAddress, amount);
          toast("⏳ Approve submitted — " + txLink(ap.hash), "info", 12000);
          await ap.wait();
        }
        await send(vaultRW.endow(amount), "Endowed — irrevocable");
        $("#endow-amount").value = "";
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-income").addEventListener("click", async () => {
      try {
        await requireSigner();
        const amt = $("#income-amount").value;
        if (!amt || Number(amt) <= 0) return toast("Amount must be > 0", "error");
        const amount = ethers.parseEther(amt);
        const allowance = await stableTok.allowance(account, vaultAddress);
        if (allowance < amount) {
          const ap = await stableTok.connect(signer).approve(vaultAddress, amount);
          toast("⏳ Approve submitted — " + txLink(ap.hash), "info", 12000);
          await ap.wait();
        }
        await send(vaultRW.recordIncome(amount), "Income recorded");
        $("#income-amount").value = "";
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-distribute").addEventListener("click", async () => {
      try {
        await requireSigner();
        const targets = await registryRO.distributionTargets();
        await send(vaultRW.distribute(targets[0], targets[1]), "Distributed to beneficiaries");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-add-beneficiary").addEventListener("click", async () => {
      try {
        await requireSigner();
        const addr = $("#beneficiary-address").value.trim();
        const w = $("#beneficiary-weight").value;
        if (!ethers.isAddress(addr)) return toast("Invalid beneficiary address", "error");
        if (!w || Number(w) < 1 || Number(w) > 10000) return toast("Weight must be 1–10000 bps", "error");
        await send(registryRW.addBeneficiary(ethers.getAddress(addr), Number(w)), "Beneficiary added");
        $("#beneficiary-address").value = ""; $("#beneficiary-weight").value = "";
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#proposal-list").addEventListener("click", async (e) => {
      const btn = e.target.closest("[data-action]");
      if (!btn) return;
      const id = Number(btn.dataset.id);
      const action = btn.dataset.action;
      try {
        await requireSigner();
        btn.disabled = true;
        btn.innerHTML = '<span class="spin">◌</span>…';
        if (action === "confirm") await send(governorRW.confirm(id), "Confirmed");
        else if (action === "vote-for") await send(governorRW.vote(id, true), "Vote cast");
        else if (action === "vote-against") await send(governorRW.vote(id, false), "Vote cast");
        else if (action === "execute") await send(governorRW.execute(id), "Executed");
        else if (action === "cancel") await send(governorRW.cancel(id), "Canceled");
        btn.disabled = false;
      } catch (err) {
        btn.disabled = false;
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    $("#form-propose").addEventListener("submit", async (e) => {
      e.preventDefault();
      try {
        await requireSigner();
        const pType = $("#p-type").value;
        const calldata = $("#p-calldata").value.trim() || "0x";
        const desc = $("#p-desc").value.trim();
        if (!desc) return toast("Add a description", "error");
        if (!/^0x[0-9a-fA-F]*$/.test(calldata)) return toast("Calldata must be hex (0x…)", "error");
        const target = pType === "4" ? cfg.governorAddress : cfg.registryAddress;
        if (pType === "3") {
          // operational spend targets the vault
          await send(governorRW.propose(pType, [vaultAddress], [0n], [calldata], desc), "Proposal created");
        } else {
          await send(governorRW.propose(pType, [target], [0n], [calldata], desc), "Proposal created");
        }
        $("#p-calldata").value = ""; $("#p-desc").value = "";
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    setInterval(() => { if (vaultRO) { refreshVault(); refreshProposals(); } }, 30000);
  }

  async function requireSigner() {
    if (!vaultRO || !vaultAddress) {
      const e = new Error("no vault"); e.__handled = true;
      toast("Configure the vault address first (Settings or the banner above)", "error");
      throw e;
    }
    if (!signer) {
      const e = new Error("no signer"); e.__handled = true;
      toast("Connect your wallet first", "error");
      throw e;
    }
    if (!vaultRW) vaultRW = new ethers.Contract(vaultAddress, ABI_V, signer);
    if (!registryRW) registryRW = new ethers.Contract(cfg.registryAddress, ABI_R, signer);
    if (!governorRW) governorRW = new ethers.Contract(cfg.governorAddress, ABI_G, signer);
  }

  async function send(txPromise, label) {
    const tx = await txPromise;
    toast("⏳ " + label + " submitted — " + txLink(tx.hash), "info", 12000);
    await tx.wait();
    toast("✅ " + label + " confirmed — " + txLink(tx.hash), "success", 9000);
    await refreshAll();
  }

  function saveSettings() {
    const addr = $("#set-vault-address").value.trim();
    if (addr && !ethers.isAddress(addr)) return toast("Invalid vault address", "error");
    if (addr) {
      vaultAddress = ethers.getAddress(addr);
      localStorage.setItem(LS_ADDRESS, vaultAddress);
    } else localStorage.removeItem(LS_ADDRESS);
    localStorage.setItem(LS_CHAIN, $("#set-chain").value);
    location.reload();
  }

  document.addEventListener("DOMContentLoaded", init);
})();
