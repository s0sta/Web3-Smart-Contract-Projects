/* ============================================================
   Huwiyya dApp — application logic
   ethers.js v6 (UMD global), no build step.
   ============================================================ */

"use strict";

(function () {
  const $ = (s) => document.querySelector(s);
  const cfg = window.APP_CONFIG || {};
  const ABI_REG = window.HUWIYYAREGISTRY_ABI || [];
  const ABI_SCH = window.HUWIYYASCHEMA_ABI || [];
  const ABI_TRS = window.HUWIYYATREASURY_ABI || [];
  const ABI_CRD = window.HUWIYYACREDENTIALS_ABI || [];
  const ABI_ATT = window.HUWIYYAATTESTATIONS_ABI || [];
  const ABI_REP = window.HUWIYYAREPUTATION_ABI || [];
  const ABI_GAT = window.HUWIYYAGATES_ABI || [];
  const ABI_REC = window.HUWIYYARECOVERY_ABI || [];
  const ABI_GOV = window.HUWIYYAGOVERNOR_ABI || [];
  const ABI_FEE = window.HUWIYYA_FEE_ABI || [];

  const LS_ADDRESS = "huwiyya.registryAddress";
  const LS_CHAIN = "huwiyya.chainId";

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

  const schemaId = cfg.schemaId || 0;

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
    RO.schemas = new ethers.Contract(cfg.schemasAddress, ABI_SCH, readProvider);
    RO.treasury = new ethers.Contract(cfg.treasuryAddress, ABI_TRS, readProvider);
    RO.credentials = new ethers.Contract(cfg.credentialsAddress, ABI_CRD, readProvider);
    RO.attestations = new ethers.Contract(cfg.attestationsAddress, ABI_ATT, readProvider);
    RO.reputation = new ethers.Contract(cfg.reputationAddress, ABI_REP, readProvider);
    RO.gates = new ethers.Contract(cfg.gatesAddress, ABI_GAT, readProvider);
    RO.recovery = new ethers.Contract(cfg.recoveryAddress, ABI_REC, readProvider);
    RO.governor = new ethers.Contract(cfg.governorAddress, ABI_GOV, readProvider);
    RO.fee = new ethers.Contract(cfg.feeTokenAddress, ABI_FEE, readProvider);
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
    await refreshIdentity();
  }

  function renderWalletButton() {
    const btn = $("#btn-connect");
    btn.textContent = account ? shortAddr(account) : "Connect Wallet";
    btn.title = account || "";
  }

  async function refreshIdentity(silent) {
    if (!RO.registry) return;
    try {
      if (account) {
        const did = await RO.registry.dids(account);
        const active = await RO.registry.isActive(account);
        $("#did-name").textContent = "DID · " + shortAddr(account);
        $("#did-address").textContent = account;
        $("#did-active").textContent = active ? "ACTIVE" : "INACTIVE";
        $("#did-active").classList.toggle("status-ok", active);
        const score = await RO.reputation.scoreOf(account);
        const band = await RO.reputation.bandOf(score);
        $("#did-score").textContent = String(score);
        $("#did-band").textContent = band;
        $("#rep-score").textContent = String(score);
        $("#rep-band").textContent = band;
        did; // the record itself is shown via the badges
      } else {
        $("#did-name").textContent = "Connect to view your DID";
        $("#did-score").textContent = "—";
      }

      // governance
      let rows = "";
      let pn = 0;
      try { while (true) { await RO.governor.proposals(pn); pn++; } } catch {}
      for (let i = pn - 1; i >= 0 && i >= pn - 8; i--) {
        const p = await RO.governor.proposals(i);
        const st = Number(await RO.governor.state(i));
        rows +=
          '<div class="item-row"><span class="mono">#' + i + "</span>" +
          '<span class="muted small">' + (p.description || "") + "</span>" +
          '<span class="item-right">' + GOV_STATES[st] + "</span>" +
          (st === 1 ? '<div class="item-actions"><button class="btn btn-ghost btn-sm" data-action="vote-for" data-id="' + i + '">For</button><button class="btn btn-ghost btn-sm" data-action="vote-against" data-id="' + i + '">Against</button></div>' : "") +
          (st === 3 ? '<div class="item-actions"><button class="btn btn-primary btn-sm" data-action="execute" data-id="' + i + '">Execute</button></div>' : "") +
          "</div>";
      }
      $("#gov-list").innerHTML = rows || '<p class="muted">no proposals yet</p>';

      // my credentials
      let rows2 = "";
      if (account) {
        const ids = await RO.credentials.credentialsOfList(account);
        for (const id of ids) {
          const c = await RO.credentials.credentials(id);
          const valid = await RO.credentials.isValid(id);
          rows2 +=
            '<div class="item-row"><span class="mono">#' + id.toString() + "</span>" +
            '<span class="muted small">schema ' + c.schemaId.toString() + " · " + shortAddr(c.issuer) + "</span>" +
            '<span class="item-right">' + (valid ? "VALID" : "REVOKED/EXPIRED") + "</span></div>";
        }
      }
      $("#cred-list").innerHTML = rows2 || '<p class="muted">no credentials yet</p>';
    } catch (err) {
      console.warn("identity:", err);
      const fallbacks = chainCfg(chainId ?? chainIdPref).rpcFallbacks || [];
      if (rpcFailures < fallbacks.length) {
        rpcFailures++;
        rebuildReadProvider();
        await refreshIdentity(silent);
        return;
      }
      rpcFailures = 0;
      rebuildReadProvider();
      if (!silent) toast("Could not read the registry — " + (err.shortMessage || err.message || ""), "error", 9000);
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

    $("#btn-create-did").addEventListener("click", async () => {
      try {
        await requireSigner();
        await send(RW.registry.createDid(ethers.id("did-doc")), "DID created");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-issue").addEventListener("click", async () => {
      try {
        await requireSigner();
        const subject = $("#cred-subject").value.trim();
        const root = $("#cred-root").value.trim();
        if (!ethers.isAddress(subject)) return toast("Invalid subject address", "error");
        if (!root || !root.startsWith("0x")) return toast("Claims root must be a 0x hex", "error");
        const fee = await RO.credentials.issuanceFee();
        const allowance = await RO.fee.allowance(account, cfg.credentialsAddress);
        if (fee > 0n && allowance < fee) {
          const ap = await RO.fee.connect(signer).approve(cfg.credentialsAddress, fee * 2n);
          toast("⏳ Approve submitted — " + txLink(ap.hash), "info", 12000);
          await ap.wait();
        }
        await send(RW.credentials.issue(ethers.getAddress(subject), BigInt(schemaId), root, 0, true), "Credential issued");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-attest").addEventListener("click", async () => {
      try {
        await requireSigner();
        const subject = $("#att-subject").value.trim();
        const score = $("#att-score").value;
        if (!ethers.isAddress(subject)) return toast("Invalid subject address", "error");
        if (!score || Number(score) < 1 || Number(score) > 1000) return toast("Score must be 1–1000", "error");
        await send(RW.attestations.submit(ethers.getAddress(subject), 1, Number(score), 0, ethers.id("evidence")), "Attestation submitted");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-propose").addEventListener("click", async () => {
      try {
        await requireSigner();
        const fee = $("#gov-fee").value;
        if (fee === "" || Number(fee) < 0) return toast("Fee must be ≥ 0", "error");
        const calldata = RO.credentials.interface.encodeFunctionData("setIssuanceFee", [ethers.parseEther(fee)]);
        await send(RW.governor.propose(cfg.credentialsAddress, 0n, calldata, "Set issuance fee to " + fee), "Proposal created");
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

    setInterval(() => { if (RO.registry) refreshIdentity(); }, 30000);
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
    RW.credentials = new ethers.Contract(cfg.credentialsAddress, ABI_CRD, signer);
    RW.attestations = new ethers.Contract(cfg.attestationsAddress, ABI_ATT, signer);
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
