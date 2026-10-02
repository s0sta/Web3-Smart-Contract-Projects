/* ============================================================
   MultiSig Vault dApp — application logic
   ethers.js v6 (UMD global), no build step.
   ============================================================ */

"use strict";

(function () {
  const $ = (s) => document.querySelector(s);
  const cfg = window.APP_CONFIG || {};
  const ABI = window.MULTISIG_ABI || [];

  const LS_ADDRESS = "multisig.walletAddress";
  const LS_CHAIN = "multisig.chainId";

  /* ---------------- state ---------------- */
  let ifaceW = null;
  let walletAddress = localStorage.getItem(LS_ADDRESS) || cfg.walletAddress || "";
  let chainIdPref = Number(localStorage.getItem(LS_CHAIN) || cfg.defaultChainId);
  let readProvider = null;
  let walletProvider = null;
  let signer = null;
  let account = null;
  let walletRO = null;
  let walletRW = null;
  let chainId = null;
  let owners = [];
  let threshold = 0;
  let txCount = 0;
  let isOwnerMe = false;

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
    if (err.data && ifaceW) {
      try {
        const e = ifaceW.parseError(err.data);
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

  function spawnShards() {
    const box = $("#shards");
    for (let i = 0; i < 12; i++) {
      const s = document.createElement("i");
      s.style.left = Math.random() * 100 + "%";
      s.style.animationDuration = 10 + Math.random() * 14 + "s";
      s.style.animationDelay = Math.random() * 10 + "s";
      box.appendChild(s);
    }
  }

  async function init() {
    if (typeof ethers === "undefined") {
      toast("ethers.js failed to load — check your internet connection", "error", 12000);
      return;
    }
    ifaceW = new ethers.Interface(ABI);
    spawnShards();

    try {
      const res = await fetch("api/config.php", { cache: "no-store" });
      if (res.ok) {
        const data = await res.json();
        if (data && data.walletAddress && !localStorage.getItem(LS_ADDRESS)) {
          walletAddress = data.walletAddress;
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
    walletAddress = localStorage.getItem(LS_ADDRESS) || walletAddress || "";

    readProvider = new ethers.JsonRpcProvider(rpcFor(chainIdPref));
    chainId = chainIdPref;

    if (walletAddress && ethers.isAddress(walletAddress)) {
      walletRO = new ethers.Contract(walletAddress, ABI, readProvider);
    } else {
      walletRO = null;
    }
    walletRW = null;

    $("#setup-banner").hidden = !!walletRO;
    $("#chain-badge").textContent = chainCfg(chainIdPref).name;
    $("#chain-badge").classList.toggle("ok", !!chainCfg(chainIdPref).rpc);
    $("#hero-address").textContent = walletRO ? walletAddress : "not configured";
    $("#footer-address").textContent = walletRO ? shortAddr(walletAddress) : "not configured";
    const ex = chainCfg(chainIdPref).explorer;
    $("#link-contract").href = walletRO && ex ? ex + "/address/" + walletAddress : "#";
    $("#link-contract").style.display = walletRO && ex ? "" : "none";
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
      walletRW = null;
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
    await refreshOwners();
    await refreshTxs();
    await refreshEvents();
  }

  function renderWalletButton() {
    const btn = $("#btn-connect");
    btn.textContent = account ? shortAddr(account) : "Connect Wallet";
    btn.title = account || "";
  }

  async function refreshStats(silent) {
    if (!walletRO) {
      $("#stat-balance").textContent = "—";
      $("#stat-owners").textContent = "—";
      $("#stat-threshold").textContent = "—";
      $("#stat-txcount").textContent = "—";
      $("#stat-role").textContent = "—";
      return;
    }
    try {
      const [balance, ownersList, thr, count, myOwner] = await Promise.all([
        readProvider.getBalance(walletAddress),
        walletRO.getOwners(),
        walletRO.threshold(),
        walletRO.transactionCount(),
        account ? walletRO.isOwner(account) : Promise.resolve(false),
      ]);
      owners = ownersList;
      threshold = Number(thr);
      txCount = Number(count);
      isOwnerMe = myOwner;

      const b = fmtEth(balance);
      $("#stat-balance").textContent = b.short + " ETH";
      $("#stat-balance").title = b.full;
      $("#stat-owners").textContent = owners.length.toString();
      $("#stat-threshold").textContent = threshold + "-of-" + owners.length;
      $("#stat-txcount").textContent = txCount.toString();
      $("#stat-role").textContent = !account
        ? "connect your wallet to check signer status"
        : isOwnerMe ? "✅ signer — you can submit, confirm and execute" : "not a signer — read-only";
    } catch (err) {
      console.warn("stats:", err);
      if (!silent) toast("Could not read the wallet — is the address correct on this network?", "error", 9000);
    }
  }

  async function refreshOwners() {
    const strip = $("#owners-strip");
    if (!walletRO || owners.length === 0) {
      strip.textContent = "loading…";
      return;
    }
    strip.innerHTML = owners
      .map((o, i) => {
        const me = account && o.toLowerCase() === account.toLowerCase();
        return (
          '<div class="owner-chip' + (me ? " me" : "") + '" style="animation-delay:' + i * 60 + 'ms">' +
          '<span class="owner-avatar">' + (i + 1) + "</span>" +
          addrLink(o) + (me ? ' <span class="me-badge">you</span>' : "") +
          "</div>"
        );
      })
      .join("");
  }

  async function refreshTxs() {
    const list = $("#tx-list");
    if (!walletRO) {
      list.innerHTML = '<div class="card center muted">Deploy the wallet to see transactions</div>';
      return;
    }
    try {
      $("#txs-note").textContent = txCount === 0 ? "no transactions yet" : txCount + " total";
      if (txCount === 0) {
        list.innerHTML = '<div class="card center muted">No transactions yet — signers can propose the first one above</div>';
        return;
      }
      const cards = [];
      for (let i = txCount - 1; i >= 0; i--) {
        cards.push(await renderTxCard(i));
      }
      list.innerHTML = cards.join("");
    } catch (err) {
      console.warn("txs:", err);
      list.innerHTML = '<div class="card center muted">Could not load transactions</div>';
    }
  }

  async function renderTxCard(id) {
    const [dest, value, data, executed] = await walletRO.transactions(id);
    const count = Number(await walletRO.getConfirmationCount(id));
    const confirmers = await walletRO.getConfirmations(id);
    const myConfirmed = account ? await walletRO.isConfirmed(id, account) : false;

    // ring geometry
    const R = 26;
    const C = 2 * Math.PI * R;
    const frac = threshold > 0 ? Math.min(count / threshold, 1) : 0;
    const offset = C * (1 - frac);
    const met = count >= threshold;
    const gid = "rg" + id;

    const vF = fmtEth(value);
    const state = executed
      ? '<span class="tx-state state-executed">✔ executed</span>'
      : met
        ? '<span class="tx-state state-pending pulse">ready to execute</span>'
        : '<span class="tx-state state-pending">pending confirmations</span>';

    let actions = "";
    if (!executed && isOwnerMe) {
      if (!myConfirmed) {
        actions += '<button class="btn btn-primary btn-sm" data-action="confirm" data-id="' + id + '">Confirm</button>';
      } else {
        actions += '<button class="btn btn-ghost btn-sm" data-action="revoke" data-id="' + id + '">Revoke</button>';
      }
      if (met) {
        actions += '<button class="btn btn-accent btn-sm" data-action="execute" data-id="' + id + '">Execute</button>';
      }
    } else if (!executed) {
      actions = '<span class="muted" style="font-size:12px">connect as a signer to act</span>';
    }

    const confirmerChips = confirmers.length
      ? confirmers.map((c) => addrLink(c)).join(" · ")
      : "none yet";

    return (
      '<div class="card tx-card" style="animation-delay:' + Math.min(id * 60, 300) + 'ms">' +
      '<div class="ring-wrap">' +
      '<div class="ring' + (met ? " met" : "") + '">' +
      '<svg viewBox="0 0 64 64">' +
      '<defs><linearGradient id="' + gid + '" x1="0" y1="0" x2="1" y2="1">' +
      '<stop offset="0" stop-color="#6366f1"/><stop offset="1" stop-color="#38bdf8"/>' +
      "</linearGradient></defs>" +
      '<circle class="ring-bg" cx="32" cy="32" r="' + R + '"/>' +
      '<circle class="ring-fill" cx="32" cy="32" r="' + R + '" stroke="url(#' + gid + ')" ' +
      'stroke-dasharray="' + C.toFixed(2) + '" stroke-dashoffset="' + offset.toFixed(2) + '"/>' +
      "</svg>" +
      '<span class="ring-label">' + (met ? "✓" : count + "/" + threshold) + "</span>" +
      "</div>" +
      '<span class="muted" style="font-size:11px">' + count + " of " + threshold + "</span>" +
      "</div>" +
      '<div class="tx-main">' +
      "<h4>Transaction #" + id + " — " + vF.short + " ETH</h4>" +
      '<p class="meta">to ' + addrLink(dest) + (data !== "0x" ? " · calldata " + shortAddr(data) : "") + "</p>" +
      '<div class="confirmers">' + confirmerChips + "</div>" +
      "</div>" +
      '<div class="tx-actions">' + state + actions + "</div>" +
      "</div>"
    );
  }

  /* ---------------- event feed ---------------- */

  async function refreshEvents() {
    const tbody = $("#activity-body");
    if (!walletRO) {
      tbody.innerHTML = '<tr><td colspan="4" class="muted center">Deploy the wallet to see activity</td></tr>';
      return;
    }
    try {
      const latest = await readProvider.getBlockNumber();
      const fromBlock = Math.max(0, latest - (cfg.eventLookbackBlocks || 50000));
      const logs = await readProvider.getLogs({ address: walletAddress, fromBlock, toBlock: latest });
      const decoded = logs
        .map((l) => {
          try {
            return { ...ifaceW.parseLog({ topics: l.topics, data: l.data }), blockNumber: Number(l.blockNumber), index: Number(l.index), tx: l.transactionHash };
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
      case "Deposit":
        details = addrLink(ev.args.sender) + " deposited " + fmtEth(ev.args.value).short + " ETH";
        break;
      case "Submission":
        details = "transaction #" + ev.args.txId + " submitted";
        break;
      case "Confirmation":
        details = addrLink(ev.args.sender) + " confirmed tx #" + ev.args.txId;
        break;
      case "Revocation":
        details = addrLink(ev.args.sender) + " revoked tx #" + ev.args.txId;
        break;
      case "Execution":
        details = "tx #" + ev.args.txId + " executed ✓";
        break;
      case "ExecutionFailure":
        details = "tx #" + ev.args.txId + " failed — retryable";
        break;
      case "ThresholdChanged":
        details = "threshold changed: " + ev.args.oldThreshold + " → " + ev.args.newThreshold;
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
      walletAddress = ethers.getAddress(addr);
      localStorage.setItem(LS_ADDRESS, walletAddress);
      location.reload();
    });

    // deposit ETH to the vault
    $("#btn-deposit").addEventListener("click", async () => {
      try {
        await requireWallet();
        const amt = $("#deposit-amount").value;
        if (!amt || Number(amt) <= 0) return toast("Amount must be > 0", "error");
        const tx = await signer.sendTransaction({ to: walletAddress, value: ethers.parseEther(amt) });
        toast("⏳ Deposit submitted — " + txLink(tx.hash), "info", 12000);
        await tx.wait();
        toast("✅ Deposit confirmed — " + txLink(tx.hash), "success", 9000);
        await refreshAll();
      } catch (err) {
        toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    // submit transaction
    $("#form-submit").addEventListener("submit", async (e) => {
      e.preventDefault();
      try {
        await requireWallet();
        const to = $("#submit-to").value.trim();
        if (!ethers.isAddress(to)) return toast("Invalid destination address", "error");
        const val = $("#submit-value").value;
        if (val === "" || Number(val) < 0) return toast("Invalid value", "error");
        let data = $("#submit-data").value.trim();
        if (data === "") data = "0x";
        if (data !== "0x" && !/^0x[0-9a-fA-F]*$/.test(data)) return toast("Calldata must be hex (0x…)", "error");

        const btn = e.target.querySelector("button");
        const original = btn.textContent;
        btn.disabled = true;
        btn.innerHTML = '<span class="spin">◌</span> Submitting…';
        await send(walletRW.submitTransaction(ethers.getAddress(to), ethers.parseEther(val || "0"), data), "Submitted");
        $("#submit-to").value = "";
        $("#submit-value").value = "";
        $("#submit-data").value = "";
        btn.disabled = false;
        btn.textContent = original;
      } catch (err) {
        const btn = e.target.querySelector("button");
        btn.disabled = false;
        btn.textContent = "Submit";
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    // delegated tx actions
    $("#tx-list").addEventListener("click", async (e) => {
      const btn = e.target.closest("[data-action]");
      if (!btn) return;
      const id = Number(btn.dataset.id);
      const action = btn.dataset.action;
      try {
        await requireWallet();
        const original = btn.textContent;
        btn.disabled = true;
        btn.innerHTML = '<span class="spin">◌</span>…';
        if (action === "confirm") {
          await send(walletRW.confirmTransaction(id), "Confirmed");
        } else if (action === "revoke") {
          await send(walletRW.revokeConfirmation(id), "Revoked");
        } else if (action === "execute") {
          await send(walletRW.executeTransaction(id), "Executed");
        }
        btn.disabled = false;
        btn.textContent = original;
      } catch (err) {
        btn.disabled = false;
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    // change threshold
    $("#form-threshold").addEventListener("submit", async (e) => {
      e.preventDefault();
      try {
        await requireWallet();
        const t = $("#threshold-value").value;
        if (!t || Number(t) < 1 || Number(t) > owners.length) {
          return toast("Threshold must be between 1 and " + owners.length, "error");
        }
        await send(walletRW.changeThreshold(t), "Threshold updated");
        $("#threshold-value").value = "";
      } catch (err) {
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    // live refresh
    setInterval(() => { if (walletRO) refreshStats(true); }, 15000);
    setInterval(() => { if (walletRO) refreshTxs(); }, 30000);
  }

  async function requireWallet() {
    if (!walletRO || !walletAddress) {
      const e = new Error("Configure the wallet address first");
      e.__handled = true;
      toast("Configure the wallet address first (Settings or the banner above)", "error");
      throw e;
    }
    if (!signer) {
      const e = new Error("Connect your wallet first");
      e.__handled = true;
      toast("Connect your wallet first", "error");
      throw e;
    }
    if (!walletRW) walletRW = new ethers.Contract(walletAddress, ABI, signer);
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
    const addr = $("#set-wallet-address").value.trim();
    if (addr && !ethers.isAddress(addr)) return toast("Invalid wallet address", "error");
    if (addr) {
      walletAddress = ethers.getAddress(addr);
      localStorage.setItem(LS_ADDRESS, walletAddress);
    } else {
      localStorage.removeItem(LS_ADDRESS);
    }
    localStorage.setItem(LS_CHAIN, $("#set-chain").value);
    location.reload();
  }

  function copyAddress() {
    if (!walletAddress) return;
    navigator.clipboard.writeText(walletAddress).then(
      () => toast("Address copied to clipboard", "success"),
      () => toast("Copy failed — address: " + walletAddress, "info", 9000)
    );
  }

  /* ---------------- boot ---------------- */

  document.addEventListener("DOMContentLoaded", init);
})();
