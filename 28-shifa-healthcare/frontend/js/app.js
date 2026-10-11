/* ============================================================
   Shifa dApp — application logic
   ethers.js v6 (UMD global), no build step.
   ============================================================ */

"use strict";

(function () {
  const $ = (s) => document.querySelector(s);
  const cfg = window.APP_CONFIG || {};

  const ABI = {
    registry: window.SHIFAREGISTRY_ABI || [],
    consent: window.SHIFACONSENT_ABI || [],
    records: window.SHIFARECORDS_ABI || [],
    prescriptions: window.SHIFAPRESCRIPTIONS_ABI || [],
    emergency: window.SHIFAEMERGENCY_ABI || [],
    appointments: window.SHIFAAPPOINTMENTS_ABI || [],
    treasury: window.SHIFATREASURY_ABI || [],
    insurance: window.SHIFAINSURANCE_ABI || [],
    payments: window.SHIFAPAYMENTS_ABI || [],
    reputation: window.SHIFAREPUTATION_ABI || [],
    governor: window.SHIFAGOVERNOR_ABI || [],
    sar: window.SHIFA_SAR_ABI || [],
  };

  const ROLES = ["—", "Patient", "Doctor", "Clinic", "Pharmacist", "Insurer"];
  const KINDS = ["Note", "Lab", "Imaging", "Vaccination", "Surgery", "Allergy"];
  const APPTS = ["Booked", "Completed", "Canceled", "NoShow"];
  const GOV_STATES = ["Review", "Voting", "Timelock", "Succeeded", "Executed", "Defeated", "Canceled"];

  const LS_ADDRESS = "shifa.registryAddress";
  const LS_CHAIN = "shifa.chainId";

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
  let ifaceGovernor = null;

  /* ---------------- helpers ---------------- */

  function chainCfg(id) {
    return cfg.chains[id] || { name: "Unknown network", short: "unknown", rpc: null, explorer: null, currency: "ETH" };
  }
  function rpcFor(id) { return chainCfg(id).rpc || "https://ethereum-sepolia-rpc.publicnode.com"; }
  function fallbackRpc(id) {
    const list = chainCfg(id).rpcFallbacks || [];
    return list.length ? list[rpcFailures % list.length] : rpcFor(id);
  }
  function shortAddr(a) {
    if (!a) return "—";
    a = String(a);
    return a.length > 12 ? a.slice(0, 6) + "…" + a.slice(-4) : a;
  }
  function fmt(bn, dec = 18) {
    try {
      return new Intl.NumberFormat("en", { maximumFractionDigits: 2 }).format(Number(ethers.formatUnits(bn, dec)));
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
    if (err.data && ifaceGovernor) {
      try { const e = ifaceGovernor.parseError(err.data); if (e) return e.name; } catch {}
    }
    if (err.shortMessage) {
      if (err.shortMessage.includes("user rejected")) return "Transaction rejected in wallet";
      return err.shortMessage;
    }
    return err.message || String(err);
  }

  /* ---------------- setup ---------------- */

  async function init() {
    if (typeof ethers === "undefined") {
      toast("ethers.js failed to load — check your internet connection", "error", 12000);
      return;
    }
    ifaceGovernor = new ethers.Interface(ABI.governor);

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

  function buildReadContracts(provider) {
    RO.registry = registryAddress ? new ethers.Contract(registryAddress, ABI.registry, provider) : null;
    RO.consent = new ethers.Contract(cfg.consentAddress, ABI.consent, provider);
    RO.records = new ethers.Contract(cfg.recordsAddress, ABI.records, provider);
    RO.prescriptions = new ethers.Contract(cfg.prescriptionsAddress, ABI.prescriptions, provider);
    RO.appointments = new ethers.Contract(cfg.appointmentsAddress, ABI.appointments, provider);
    RO.insurance = new ethers.Contract(cfg.insuranceAddress, ABI.insurance, provider);
    RO.payments = new ethers.Contract(cfg.paymentsAddress, ABI.payments, provider);
    RO.reputation = new ethers.Contract(cfg.reputationAddress, ABI.reputation, provider);
    RO.governor = new ethers.Contract(cfg.governorAddress, ABI.governor, provider);
    RO.sar = new ethers.Contract(cfg.sarAddress, ABI.sar, provider);
  }

  function applyAddressAndChain() {
    let savedChain = Number(localStorage.getItem(LS_CHAIN) || cfg.defaultChainId);
    if (!cfg.chains[savedChain]) { savedChain = cfg.defaultChainId; localStorage.removeItem(LS_CHAIN); }
    chainIdPref = savedChain;
    registryAddress = localStorage.getItem(LS_ADDRESS) || registryAddress || "";

    const rpc = rpcFailures > 0 ? fallbackRpc(chainIdPref) : rpcFor(chainIdPref);
    readProvider = new ethers.JsonRpcProvider(rpc);
    chainId = chainIdPref;
    if (registryAddress && ethers.isAddress(registryAddress)) buildReadContracts(readProvider);

    $("#setup-banner").hidden = !!RO.registry;
    $("#chain-badge").textContent = chainCfg(chainIdPref).name;
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
        else toast("You are on " + chainCfg(chainId).name + " — switch to " + chainCfg(chainIdPref).name, "info", 9000);
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
    $("#btn-connect").textContent = account ? shortAddr(account) : "Connect Wallet";
    await refreshVitals();
  }

  async function refreshVitals(silent) {
    if (!RO.registry) return;
    try {
      const role = account ? Number((await RO.registry.members(account)).role) : 0;
      $("#strip-role").textContent = ROLES[role] || "—";

      if (account) {
        const recIds = await RO.records.recordsOf(account);
        const rxIds = await RO.prescriptions.prescriptionsOf(account);
        $("#strip-records").textContent = recIds.length + " on file";
        $("#strip-rx").textContent = rxIds.length + " issued";

        const planId = await RO.insurance.planOf(account);
        const plan = await RO.insurance.plans(planId);
        $("#strip-cover").textContent = Number(plan.member) === 0 ? "—" :
          fmt(await RO.insurance.planCoverLeft(planId)) + " SAR";

        $("#strip-reputation").textContent = String(await RO.reputation.scoreOf(account));
        await renderConsents(account);
        await renderRecords(recIds);
        await renderPrescriptions(rxIds);
        await renderAppointments(account);
        await renderClaims(planId);
      }
      await renderProposals();
    } catch (err) {
      console.warn("vitals:", err);
      const list = chainCfg(chainId ?? chainIdPref).rpcFallbacks || [];
      if (rpcFailures < list.length) {
        rpcFailures++;
        buildReadContracts(new ethers.JsonRpcProvider(fallbackRpc(chainId ?? chainIdPref)));
        await refreshVitals(silent);
        return;
      }
      rpcFailures = 0;
      if (!silent) toast("Could not read the platform — " + (err.shortMessage || err.message || ""), "error", 9000);
    }
  }

  async function renderConsents(patient) {
    let rows = "";
    const providers = await RO.consent.providersOfList(patient);
    for (const p of providers) {
      const g = await RO.consent.grants(patient, p);
      if (!g.active) continue;
      const live = Number(g.expiresAt) > Math.floor(Date.now() / 1000);
      rows += '<div class="item-row"><span class="mono">' + shortAddr(p) + "</span>" +
        '<span class="muted small">scope ' + g.scope + (live ? "" : " · expired") + "</span>" +
        '<span class="item-right">' + new Date(Number(g.expiresAt) * 1000).toLocaleDateString() + "</span>" +
        (live ? '<div class="item-actions"><button class="btn btn-ghost btn-sm" data-action="revoke" data-addr="' + p + '">Revoke</button></div>' : "") +
        "</div>";
    }
    $("#consent-list").innerHTML = rows || '<p class="muted">no consents yet</p>';
  }

  async function renderRecords(ids) {
    let rows = "";
    for (const id of ids.slice(-8).reverse()) {
      const r = await RO.records.records(id);
      rows += '<div class="item-row"><span class="mono">#' + id + "</span>" +
        '<span class="muted small">' + (KINDS[Number(r.kind)] || "?") + " · " + shortAddr(r.author) + "</span>" +
        '<span class="item-right mono">' + shortAddr(r.contentHash) + "</span>" +
        '<div class="item-actions"><button class="btn btn-ghost btn-sm" data-action="read" data-id="' + id + '">Read</button></div></div>';
    }
    $("#record-list").innerHTML = rows || '<p class="muted">no records yet</p>';
  }

  async function renderPrescriptions(ids) {
    let rows = "";
    for (const id of ids.slice(-8).reverse()) {
      const p = await RO.prescriptions.prescriptions(id);
      const left = await RO.prescriptions.refillsLeft(id);
      rows += '<div class="item-row"><span class="mono">#' + id + "</span>" +
        '<span class="muted small">' + p.doseMg + " mg · " + left + " refills left" + (p.controlled ? " · controlled" : "") + "</span>" +
        '<span class="item-right mono">' + shortAddr(p.drugHash) + "</span>" +
        (Number(left) > 0 && !p.canceled
          ? '<div class="item-actions"><button class="btn btn-ghost btn-sm" data-action="dispense" data-id="' + id + '">Dispense</button></div>'
          : "") +
        "</div>";
    }
    $("#rx-list").innerHTML = rows || '<p class="muted">no prescriptions yet</p>';
  }

  async function renderAppointments(patient) {
    let rows = "";
    const ids = await RO.appointments.appointmentsOf(patient);
    for (const id of ids.slice(-6).reverse()) {
      const a = await RO.appointments.appointments(id);
      const status = APPTS[Number(a.status)] || "?";
      rows += '<div class="item-row"><span class="mono">#' + id + "</span>" +
        '<span class="muted small">' + shortAddr(a.provider) + " · " + new Date(Number(a.slot) * 1000).toLocaleDateString() + " · " + status + "</span>" +
        '<span class="item-right">' + fmt(a.deposit) + " SAR</span>" +
        (Number(a.status) === 0
          ? '<div class="item-actions"><button class="btn btn-ghost btn-sm" data-action="cancel-appt" data-id="' + id + '">Cancel</button>' +
            '<button class="btn btn-ghost btn-sm" data-action="complete-appt" data-id="' + id + '">Complete</button></div>'
          : "") +
        (Number(a.status) === 1
          ? '<div class="item-actions"><button class="btn btn-ghost btn-sm" data-action="rate" data-id="' + id + '">Rate 90</button></div>'
          : "") +
        "</div>";
    }
    $("#appt-list").innerHTML = rows || '<p class="muted">no visits yet</p>';
  }

  async function renderClaims(planId) {
    let rows = "";
    const total = Number(await RO.insurance.claimsCount());
    for (let id = total - 1; id >= 0 && id >= total - 6; id--) {
      const c = await RO.insurance.claims(id);
      if (shortAddr(c.provider) === "—") continue;
      rows += '<div class="item-row"><span class="mono">#' + id + "</span>" +
        '<span class="muted small">' + fmt(c.amount) + " SAR · insurer " + fmt(c.insurerShare) + " · you " + fmt(c.patientShare) + "</span>" +
        '<span class="item-right">' + (c.paid ? "paid" : c.decided ? "rejected" : "review") + "</span>" +
        (c.paid && Number(c.patientShare) > 0
          ? '<div class="item-actions"><button class="btn btn-ghost btn-sm" data-action="copay" data-id="' + id + '">Pay copay</button></div>'
          : "") +
        "</div>";
    }
    planId; // the plan is shown in the vitals strip; claims are listed platform-wide
    $("#claim-list").innerHTML = rows || '<p class="muted">no claims yet</p>';
  }

  async function renderProposals() {
    let rows = "";
    let n = 0;
    try { while (true) { await RO.governor.proposals(n); n++; } } catch {}
    for (let i = n - 1; i >= 0 && i >= n - 6; i--) {
      const p = await RO.governor.proposals(i);
      const st = Number(await RO.governor.state(i));
      rows += '<div class="item-row"><span class="mono">#' + i + "</span>" +
        '<span class="muted small">' + (p.description || "") + "</span>" +
        '<span class="item-right">' + (GOV_STATES[st] || "?") + "</span>" +
        (st === 1 ? '<div class="item-actions"><button class="btn btn-ghost btn-sm" data-action="vote-for" data-id="' + i + '">For</button><button class="btn btn-ghost btn-sm" data-action="vote-against" data-id="' + i + '">Against</button></div>' : "") +
        (st === 3 ? '<div class="item-actions"><button class="btn btn-primary btn-sm" data-action="execute" data-id="' + i + '">Execute</button></div>' : "") +
        "</div>";
    }
    $("#gov-list").innerHTML = rows || '<p class="muted">no proposals yet</p>';
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

    $("#btn-register").addEventListener("click", () => act(async () => {
      const role = Number($("#reg-role").value);
      await send(RW.registry.register(role, 682, ethers.id("license-" + Date.now())), "Registered");
    }));

    $("#btn-consent").addEventListener("click", () => act(async () => {
      const provider = $("#consent-provider").value.trim();
      if (!ethers.isAddress(provider)) return toast("Enter a valid provider address", "error");
      const scope = Number($("#consent-scope").value);
      const expiresAt = Math.floor(Date.now() / 1000) + 90 * 86400;
      await send(RW.consent.grant(provider, scope, expiresAt), "Consent granted for 90 days");
    }));

    $("#consent-list").addEventListener("click", (e) => {
      const btn = e.target.closest("[data-action='revoke']");
      if (!btn) return;
      act(async () => { await send(RW.consent.revoke(btn.dataset.addr), "Consent revoked"); });
    });

    $("#btn-record").addEventListener("click", () => act(async () => {
      const patient = $("#rec-patient").value.trim();
      const hash = $("#rec-hash").value.trim();
      if (!ethers.isAddress(patient)) return toast("Enter the patient address", "error");
      if (!/^0x[0-9a-fA-F]{64}$/.test(hash)) return toast("The document hash must be 32 bytes (0x…64 hex)", "error");
      await send(RW.records.createRecord(patient, Number($("#rec-kind").value), hash), "Record filed");
    }));

    $("#record-list").addEventListener("click", (e) => {
      const btn = e.target.closest("[data-action='read']");
      if (!btn) return;
      act(async () => {
        const hash = await RW.records.readRecord.staticCall(BigInt(btn.dataset.id));
        toast("📋 Record #" + btn.dataset.id + " fingerprint: <span class='mono'>" + hash + "</span>", "success", 12000);
        await send(RW.records.readRecord(BigInt(btn.dataset.id)), "Read logged on-chain");
      });
    });

    $("#btn-issue").addEventListener("click", () => act(async () => {
      const patient = $("#rx-patient").value.trim();
      const drug = $("#rx-drug").value.trim();
      if (!ethers.isAddress(patient)) return toast("Enter the patient address", "error");
      if (!/^0x[0-9a-fA-F]{64}$/.test(drug)) return toast("The drug hash must be 32 bytes (0x…64 hex)", "error");
      const dose = Number($("#rx-dose").value || 0);
      const refills = Number($("#rx-refills").value || 0);
      const days = Number($("#rx-days").value || 0);
      if (dose < 1 || days < 1 || days > 180) return toast("Dose ≥ 1 mg and validity 1–180 days", "error");
      await send(RW.prescriptions.issue(patient, drug, dose, refills, days, false), "Prescription issued");
    }));

    $("#rx-list").addEventListener("click", (e) => {
      const btn = e.target.closest("[data-action='dispense']");
      if (!btn) return;
      act(async () => { await send(RW.prescriptions.dispense(BigInt(btn.dataset.id)), "Dispensed"); });
    });

    $("#btn-book").addEventListener("click", () => act(async () => {
      const provider = $("#appt-provider").value.trim();
      if (!ethers.isAddress(provider)) return toast("Enter the doctor or clinic address", "error");
      const days = Number($("#appt-days").value || 0);
      const deposit = $("#appt-deposit").value;
      if (days < 1 || !deposit || Number(deposit) <= 0) return toast("Days ≥ 1 and a deposit", "error");
      const amount = ethers.parseEther(String(deposit));
      await ensureAllowance(cfg.appointmentsAddress, amount);
      const slot = Math.floor(Date.now() / 1000) + days * 86400;
      await send(RW.appointments.book(provider, slot, amount), "Visit booked");
    }));

    $("#appt-list").addEventListener("click", (e) => {
      const btn = e.target.closest("[data-action]");
      if (!btn) return;
      const id = BigInt(btn.dataset.id);
      const action = btn.dataset.action;
      act(async () => {
        if (action === "cancel-appt") await send(RW.appointments.cancel(id), "Visit canceled");
        else if (action === "complete-appt") await send(RW.appointments.complete(id), "Visit completed");
        else if (action === "rate") await send(RW.reputation.rate(id, 90), "Rated 90/100");
      });
    });

    $("#btn-subscribe").addEventListener("click", () => act(async () => {
      const insurer = $("#ins-insurer").value.trim();
      if (!ethers.isAddress(insurer)) return toast("Enter the insurer address", "error");
      const cover = $("#ins-cover").value;
      const copay = Number($("#ins-copay").value || 0);
      if (!cover || Number(cover) <= 0 || copay > 50) return toast("Cover > 0 and copay ≤ 50%", "error");
      const coverage = ethers.parseEther(String(cover));
      const premium = (coverage * 500n) / 10000n; // 5% yearly
      await ensureAllowance(cfg.insuranceAddress, premium);
      await send(RW.insurance.subscribe(insurer, coverage, copay * 100, 365), "Cover started");
    }));

    $("#claim-list").addEventListener("click", (e) => {
      const btn = e.target.closest("[data-action='copay']");
      if (!btn) return;
      act(async () => {
        const id = BigInt(btn.dataset.id);
        const c = await RO.insurance.claims(id);
        await ensureAllowance(cfg.paymentsAddress, c.patientShare);
        await send(RW.payments.payCopay(id, ethers.id("copay-" + Date.now())), "Copay settled");
      });
    });

    $("#btn-pay").addEventListener("click", () => act(async () => {
      const provider = $("#pay-provider").value.trim();
      const amount = $("#pay-amount").value;
      if (!ethers.isAddress(provider)) return toast("Enter the provider address", "error");
      if (!amount || Number(amount) <= 0) return toast("Enter an amount", "error");
      const value = ethers.parseEther(String(amount));
      await ensureAllowance(cfg.paymentsAddress, value);
      await send(RW.payments.payForService(provider, value, ethers.id("service-" + Date.now())), "Payment sent");
    }));

    $("#btn-propose").addEventListener("click", () => act(async () => {
      const bps = Number($("#gov-fee").value || 0);
      if (bps < 0 || bps > 1000) return toast("Fee must be 0–1000 bps", "error");
      const data = RO.appointments.interface.encodeFunctionData("setFee", [bps]);
      await send(RW.governor.propose(cfg.appointmentsAddress, 0, data, "Set visit fee to " + (bps / 100).toFixed(2) + "%"), "Proposal created");
    }));

    $("#gov-list").addEventListener("click", (e) => {
      const btn = e.target.closest("[data-action]");
      if (!btn) return;
      const id = BigInt(btn.dataset.id);
      const action = btn.dataset.action;
      act(async () => {
        if (action === "vote-for") await send(RW.governor.vote(id, true), "Vote cast");
        else if (action === "vote-against") await send(RW.governor.vote(id, false), "Vote cast");
        else if (action === "execute") await send(RW.governor.execute(id), "Proposal executed");
      });
    });

    setInterval(() => { if (RO.registry) refreshVitals(); }, 30000);
  }

  async function act(fn) {
    try {
      await requireSigner();
      await fn();
    } catch (err) {
      if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
    }
  }

  async function requireSigner() {
    if (!RO.registry) {
      const e = new Error("no registry"); e.__handled = true;
      toast("Configure the registry address first (Settings or the banner above)", "error");
      throw e;
    }
    if (!signer) {
      const e = new Error("no signer"); e.__handled = true;
      toast("Connect your wallet first", "error");
      throw e;
    }
    RW.registry = new ethers.Contract(registryAddress, ABI.registry, signer);
    RW.consent = new ethers.Contract(cfg.consentAddress, ABI.consent, signer);
    RW.records = new ethers.Contract(cfg.recordsAddress, ABI.records, signer);
    RW.prescriptions = new ethers.Contract(cfg.prescriptionsAddress, ABI.prescriptions, signer);
    RW.appointments = new ethers.Contract(cfg.appointmentsAddress, ABI.appointments, signer);
    RW.insurance = new ethers.Contract(cfg.insuranceAddress, ABI.insurance, signer);
    RW.payments = new ethers.Contract(cfg.paymentsAddress, ABI.payments, signer);
    RW.reputation = new ethers.Contract(cfg.reputationAddress, ABI.reputation, signer);
    RW.governor = new ethers.Contract(cfg.governorAddress, ABI.governor, signer);
    RW.sar = new ethers.Contract(cfg.sarAddress, ABI.sar, signer);
  }

  async function ensureAllowance(spender, amount) {
    const allowance = await RO.sar.allowance(account, spender);
    if (allowance >= amount) return;
    const tx = await RW.sar.approve(spender, amount * 2n);
    toast("⏳ Approve submitted — " + txLink(tx.hash), "info", 12000);
    await tx.wait();
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
