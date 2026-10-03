/* ============================================================
   StakeVault dApp — application logic
   ethers.js v6 (UMD global), no build step.
   ============================================================ */

"use strict";

(function () {
  const $ = (s) => document.querySelector(s);
  const cfg = window.APP_CONFIG || {};
  const ABI_V = window.STAKE_VAULT_ABI || [];
  const ABI_T = window.IERC20_ABI || [];

  const LS_ADDRESS = "stake.vaultAddress";
  const LS_CHAIN = "stake.chainId";

  /* ---------------- state ---------------- */
  let ifaceV = null;
  let vaultAddress = localStorage.getItem(LS_ADDRESS) || cfg.vaultAddress || "";
  let chainIdPref = Number(localStorage.getItem(LS_CHAIN) || cfg.defaultChainId);
  let readProvider = null;
  let walletProvider = null;
  let signer = null;
  let account = null;
  let vaultRO = null;
  let vaultRW = null;
  let vaultOwner = null;
  let chainId = null;
  let stakingTok = null; // token contracts (RO = read-only)
  let rewardTok = null;
  let rewardRate = 0n;
  let myShare = 0n; // balance / totalSupply as 1e18-scaled fraction for the ticker
  let myEarned = 0n;
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

  function spawnSparks() {
    const box = $("#sparks");
    for (let i = 0; i < 16; i++) {
      const s = document.createElement("i");
      s.style.left = Math.random() * 100 + "%";
      s.style.setProperty("--d", 9 + Math.random() * 10 + "s");
      s.style.animationDelay = Math.random() * 9 + "s";
      box.appendChild(s);
    }
  }

  async function init() {
    if (typeof ethers === "undefined") {
      toast("ethers.js failed to load — check your internet connection", "error", 12000);
      return;
    }
    ifaceV = new ethers.Interface(ABI_V);
    spawnSparks();

    try {
      const res = await fetch("api/config.php", { cache: "no-store" });
      if (res.ok) {
        const data = await res.json();
        if (data && data.vaultAddress && !localStorage.getItem(LS_ADDRESS)) {
          vaultAddress = data.vaultAddress;
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
    vaultAddress = localStorage.getItem(LS_ADDRESS) || vaultAddress || "";

    readProvider = new ethers.JsonRpcProvider(rpcFor(chainIdPref));
    chainId = chainIdPref;

    if (vaultAddress && ethers.isAddress(vaultAddress)) {
      vaultRO = new ethers.Contract(vaultAddress, ABI_V, readProvider);
    } else {
      vaultRO = null;
    }
    vaultRW = null;

    $("#setup-banner").hidden = !!vaultRO;
    $("#chain-badge").textContent = chainCfg(chainIdPref).name;
    $("#chain-badge").classList.toggle("ok", !!chainCfg(chainIdPref).rpc);
    $("#hero-address").textContent = vaultRO ? vaultAddress : "not configured";
    $("#footer-address").textContent = vaultRO ? shortAddr(vaultAddress) : "not configured";
    const ex = chainCfg(chainIdPref).explorer;
    $("#link-contract").href = vaultRO && ex ? ex + "/address/" + vaultAddress : "#";
    $("#link-contract").style.display = vaultRO && ex ? "" : "none";
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
      vaultRW = null;
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
    await refreshEvents();
    renderAdmin();
    startTicker();
  }

  function renderWalletButton() {
    const btn = $("#btn-connect");
    btn.textContent = account ? shortAddr(account) : "Connect Wallet";
    btn.title = account || "";
  }

  async function refreshStats(silent) {
    if (!vaultRO) {
      ["stat-total", "stat-rate", "stat-period", "stat-mystake", "stat-earned"].forEach((id) => ($("#" + id).textContent = "—"));
      return;
    }
    try {
      if (!stakingTok) {
        stakingTok = new ethers.Contract(await vaultRO.stakingToken(), ABI_T, readProvider);
        rewardTok = new ethers.Contract(await vaultRO.rewardsToken(), ABI_T, readProvider);
      }

      const [total, rate, finish, owner, bal, earned, allowance] = await Promise.all([
        vaultRO.totalSupply(),
        vaultRO.rewardRate(),
        vaultRO.periodFinish(),
        vaultRO.owner(),
        account ? vaultRO.balanceOf(account) : Promise.resolve(0n),
        account ? vaultRO.earned(account) : Promise.resolve(0n),
        account ? stakingTok.allowance(account, vaultAddress) : Promise.resolve(0n),
      ]);
      vaultOwner = owner;
      rewardRate = rate;
      myEarned = earned;

      const totalF = fmtUnits(total);
      $("#stat-total").textContent = totalF.short + " STAKE";
      $("#stat-total").title = totalF.full;

      const perDay = fmtUnits(rate * 86400n);
      $("#stat-rate").textContent = perDay.short + " REWARD / day";
      $("#stat-rate").title = perDay.full + " per day (" + fmtUnits(rate).full + "/s)";

      const cd = fmtCountdown(Number(finish) - Math.floor(Date.now() / 1000));
      $("#stat-period").textContent = "⏳ " + cd.text;

      const balF = fmtUnits(bal);
      $("#stat-mystake").textContent = account ? balF.short + " STAKE" : "—";

      if (account) {
        myShare = total > 0n ? (bal * ethers.parseUnits("1", 18)) / total : 0n;
        $("#allowance-row").hidden = false;
        $("#allowance-text").textContent = fmtUnits(allowance).short + " STAKE";
      } else {
        myShare = 0n;
        $("#allowance-row").hidden = true;
      }

      updateEarnedDisplay();
    } catch (err) {
      console.warn("stats:", err);
      if (!silent) toast("Could not read the vault — is the address correct on this network?", "error", 9000);
    }
  }

  function updateEarnedDisplay() {
    const f = fmtUnits(myEarned);
    $("#stat-earned").textContent = (account ? "" : "connect to see · ") + f.short + " REWARD";
    $("#stat-earned").title = f.full;
    $("#claim-preview").textContent = f.short;
  }

  /* the live ticker: advance earned locally at the exact per-second rate between on-chain refreshes */
  function startTicker() {
    if (tickerInterval) clearInterval(tickerInterval);
    tickerInterval = setInterval(() => {
      if (!account || !vaultRO) return;
      // earned grows by rewardRate × my share per second (matches the contract's math)
      const inc = (rewardRate * myShare) / ethers.parseUnits("1", 18);
      myEarned += inc;
      updateEarnedDisplay();
    }, 1000);
    // re-sync with the chain every 10s (corrects any drift)
    setInterval(async () => {
      if (!account || !vaultRO) return;
      try {
        myEarned = await vaultRO.earned(account);
        updateEarnedDisplay();
      } catch {}
    }, 10000);
  }

  function renderAdmin() {
    const isOwner = account && vaultOwner && account.toLowerCase() === vaultOwner.toLowerCase();
    $("#admin-section").hidden = !isOwner;
  }

  /* ---------------- event feed ---------------- */

  async function refreshEvents() {
    const tbody = $("#activity-body");
    if (!vaultRO) {
      tbody.innerHTML = '<tr><td colspan="4" class="muted center">Deploy the vault to see activity</td></tr>';
      return;
    }
    try {
      const latest = await readProvider.getBlockNumber();
      const fromBlock = Math.max(0, latest - (cfg.eventLookbackBlocks || 50000));
      const logs = await readProvider.getLogs({ address: vaultAddress, fromBlock, toBlock: latest });
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
      case "Staked":
        details = addrLink(ev.args.user) + " staked " + fmtUnits(ev.args.amount).short + " STAKE";
        break;
      case "Withdrawn":
        details = addrLink(ev.args.user) + " withdrew " + fmtUnits(ev.args.amount).short + " STAKE";
        break;
      case "RewardPaid":
        details = addrLink(ev.args.user) + " claimed " + fmtUnits(ev.args.amount).short + " REWARD";
        break;
      case "RewardsNotified":
        details = "emission: " + fmtUnits(ev.args.amount).short + " REWARD over " + (Number(ev.args.duration) / 86400).toFixed(1) + " days";
        break;
      case "EmergencyWithdrawn":
        details = addrLink(ev.args.user) + " emergency-withdrew " + fmtUnits(ev.args.amount).short + " STAKE (rewards forfeited)";
        break;
      case "Recovered":
        details = "recovered " + fmtUnits(ev.args.amount).short + " of " + addrLink(ev.args.token);
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
      vaultAddress = ethers.getAddress(addr);
      localStorage.setItem(LS_ADDRESS, vaultAddress);
      location.reload();
    });

    // approve max
    $("#btn-approve").addEventListener("click", async () => {
      try {
        await requireVault();
        const tok = new ethers.Contract(await vaultRO.stakingToken(), ABI_T, signer);
        const tx = await tok.approve(vaultAddress, ethers.MaxUint256);
        toast("⏳ Approve submitted — " + txLink(tx.hash), "info", 12000);
        await tx.wait();
        toast("✅ Approved — " + txLink(tx.hash), "success", 9000);
        await refreshAll();
      } catch (err) {
        toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    // stake
    $("#form-stake").addEventListener("submit", async (e) => {
      e.preventDefault();
      try {
        await requireVault();
        const amt = $("#stake-amount").value;
        if (!amt || Number(amt) <= 0) return toast("Amount must be > 0", "error");
        await send(vaultRW.stake(ethers.parseEther(amt)), "Staked");
        $("#stake-amount").value = "";
      } catch (err) {
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    // withdraw
    $("#form-withdraw").addEventListener("submit", async (e) => {
      e.preventDefault();
      try {
        await requireVault();
        const amt = $("#withdraw-amount").value;
        if (!amt || Number(amt) <= 0) return toast("Amount must be > 0", "error");
        await send(vaultRW.withdraw(ethers.parseEther(amt)), "Withdrawn");
        $("#withdraw-amount").value = "";
      } catch (err) {
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    // claim / exit / emergency
    $("#btn-claim").addEventListener("click", () => guarded("getReward()", "Claimed"));
    $("#btn-exit").addEventListener("click", () => guarded("exitAll()", "Exited"));
    $("#btn-emergency").addEventListener("click", async () => {
      try {
        await requireVault();
        if (!confirm("Emergency withdraw returns your PRINCIPAL only — all pending rewards are forfeited. Continue?")) return;
        await send(vaultRW.emergencyWithdraw(), "Emergency withdrawn");
      } catch (err) {
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    // admin: fund emissions
    $("#form-emit").addEventListener("submit", async (e) => {
      e.preventDefault();
      try {
        await requireVault();
        const amt = $("#emit-amount").value;
        const days = $("#emit-days").value;
        if (!amt || Number(amt) <= 0) return toast("Amount must be > 0", "error");
        if (!days || Number(days) < 1) return toast("Duration must be ≥ 1 day", "error");
        await send(vaultRW.startRewards(ethers.parseEther(amt), Math.floor(Number(days) * 86400)), "Emissions started");
      } catch (err) {
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    // admin: recover stray tokens
    $("#form-recover").addEventListener("submit", async (e) => {
      e.preventDefault();
      try {
        await requireVault();
        const tok = $("#recover-token").value.trim();
        const amt = $("#recover-amount").value;
        if (!ethers.isAddress(tok)) return toast("Invalid token address", "error");
        if (!amt || Number(amt) <= 0) return toast("Amount must be > 0", "error");
        await send(vaultRW.recoverERC20(ethers.getAddress(tok), ethers.parseEther(amt)), "Recovered");
      } catch (err) {
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    // live refresh
    setInterval(() => { if (vaultRO) refreshStats(true); }, 15000);
  }

  async function guarded(fn, label) {
    try {
      await requireVault();
      await send(vaultRW[fn](), label);
    } catch (err) {
      if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
    }
  }

  async function requireVault() {
    if (!vaultRO || !vaultAddress) {
      const e = new Error("Configure the vault address first");
      e.__handled = true;
      toast("Configure the vault address first (Settings or the banner above)", "error");
      throw e;
    }
    if (!signer) {
      const e = new Error("Connect your wallet first");
      e.__handled = true;
      toast("Connect your wallet first", "error");
      throw e;
    }
    if (!vaultRW) vaultRW = new ethers.Contract(vaultAddress, ABI_V, signer);
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
    const addr = $("#set-vault-address").value.trim();
    if (addr && !ethers.isAddress(addr)) return toast("Invalid vault address", "error");
    if (addr) {
      vaultAddress = ethers.getAddress(addr);
      localStorage.setItem(LS_ADDRESS, vaultAddress);
    } else {
      localStorage.removeItem(LS_ADDRESS);
    }
    localStorage.setItem(LS_CHAIN, $("#set-chain").value);
    location.reload();
  }

  function copyAddress() {
    if (!vaultAddress) return;
    navigator.clipboard.writeText(vaultAddress).then(
      () => toast("Address copied to clipboard", "success"),
      () => toast("Copy failed — address: " + vaultAddress, "info", 9000)
    );
  }

  /* ---------------- boot ---------------- */

  document.addEventListener("DOMContentLoaded", init);
})();
