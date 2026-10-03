/* ============================================================
   LendVault dApp — application logic
   ethers.js v6 (UMD global), no build step.
   ============================================================ */

"use strict";

(function () {
  const $ = (s) => document.querySelector(s);
  const cfg = window.APP_CONFIG || {};
  const ABI_V = window.LEND_VAULT_ABI || [];
  const ABI_S = window.STABLE_ABI || [];

  const LS_ADDRESS = "lend.vaultAddress";
  const LS_CHAIN = "lend.chainId";

  const PRICE = 2000n * ethers.parseUnits("1", 18); // 2000 USD / ETH
  const LTV = 6600n;

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
  let stableTok = null;
  let chainId = null;
  let vaultOwner = null;
  let paused = false;
  let myCollateral = 0n;
  let myDebt = 0n;
  let totalCollateral = 0n;
  let totalDebt = 0n;
  let ratePerSecond = 0n;
  let tickerInterval = null;
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
    vaultRO = new ethers.Contract(vaultAddress, ABI_V, readProvider);
    stableTok = null;
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

  function fmtUsd(bn) {
    const f = fmtUnits(bn);
    return { short: "$" + f.short, full: f.full };
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

  async function init() {
    if (typeof ethers === "undefined") {
      toast("ethers.js failed to load — check your internet connection", "error", 12000);
      return;
    }
    ifaceV = new ethers.Interface(ABI_V);

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
    } else {
      vaultRO = null;
    }
    vaultRW = null;

    $("#setup-banner").hidden = !!vaultRO;
    $("#chain-badge").textContent = chainCfg(chainIdPref).name;
    $("#chain-badge").classList.toggle("ok", !!chainCfg(chainIdPref).rpc);
    $("#footer-address").textContent = vaultRO ? shortAddr(vaultAddress) : "not configured";
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
      vaultRW = null;
      myCollateral = 0n;
      myDebt = 0n;
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
    await refreshVault();
    await refreshEvents();
  }

  function renderWalletButton() {
    const btn = $("#btn-connect");
    btn.textContent = account ? shortAddr(account) : "Connect Wallet";
    btn.title = account || "";
  }

  async function refreshVault(silent) {
    if (!vaultRO) return;
    try {
      if (!stableTok) {
        stableTok = new ethers.Contract(await vaultRO.stable(), ABI_S, readProvider);
      }
      const [pausedNow, totalC, totalD, rate, owner, myC, myD, walletEth, stableBal] = await Promise.all([
        vaultRO.paused(),
        vaultRO.totalCollateral(),
        vaultRO.totalDebt(),
        vaultRO.ratePerSecond(),
        vaultRO.owner(),
        account ? vaultRO.collateral(account) : Promise.resolve(0n),
        account ? vaultRO.currentDebt(account) : Promise.resolve(0n),
        account ? readProvider.getBalance(account) : Promise.resolve(0n),
        account ? stableTok.balanceOf(account) : Promise.resolve(0n),
      ]);
      paused = pausedNow;
      vaultOwner = owner;
      totalCollateral = totalC;
      totalDebt = totalD;
      ratePerSecond = rate;
      myCollateral = myC;
      myDebt = myD;

      // pause banner
      $("#pause-banner").hidden = !paused;
      if (account && account.toLowerCase() === owner.toLowerCase()) {
        $("#owner-controls").hidden = false;
        $("#btn-toggle-pause").textContent = paused ? "Unpause vault" : "Pause vault";
      } else {
        $("#owner-controls").hidden = true;
      }

      // utilization band
      const suppliedUsd = (totalC * PRICE) / ethers.parseUnits("1", 18);
      setUtil("util-supplied", fmtUsd(suppliedUsd).short);
      setUtil("util-borrowed", fmtUsd(totalD).short);
      const util = suppliedUsd > 0n ? Number((totalD * 10000n) / suppliedUsd) / 100 : 0;
      setUtil("util-pct", util.toFixed(1) + "%");
      $("#util-fill").style.width = Math.min(100, util).toFixed(1) + "%";
      $("#param-rate").textContent = (Number(rate) / 1e18).toExponential(3) + " /s";

      // my position
      if (account) {
        $("#wallet-eth").textContent = fmtUnits(walletEth).short + " ETH";
        $("#stable-bal").textContent = fmtUnits(stableBal).short;
        $("#my-collateral").textContent = fmtUnits(myC).short + " ETH";
        const cUsd = (myC * PRICE) / ethers.parseUnits("1", 18);
        $("#pos-supplied").textContent = fmtUsd(cUsd).short + " (" + fmtUnits(myC).short + " ETH)";
        $("#pos-debt").textContent = fmtUsd(myDebt).short;
        const limit = (cUsd * LTV) / 10000n;
        $("#pos-limit").textContent = fmtUsd(limit).short;
        const avail = limit > myDebt ? limit - myDebt : 0n;
        $("#pos-available").textContent = fmtUsd(avail).short;
        $("#pos-net").textContent = fmtUsd(cUsd - myDebt).short;
        const meterPct = limit > 0n ? Math.min(100, Number((myDebt * 10000n) / limit) / 100) : 0;
        $("#limit-fill").style.width = meterPct.toFixed(1) + "%";

        // health factor
        const hfRaw = await vaultRO.healthFactor(account);
        if (hfRaw === ethers.MaxUint256) {
          $("#hf-value").textContent = "∞";
          $("#hf-value").className = "hf-value";
          $("#hf-arc").style.strokeDashoffset = "0";
        } else {
          const hf = Number(ethers.formatUnits(hfRaw, 18));
          $("#hf-value").textContent = hf >= 100 ? ">" + hf.toFixed(0) : hf.toFixed(2);
          const el = $("#hf-value");
          el.className = "hf-value" + (hf < 1 ? " danger" : hf < 1.5 ? " bump" : "");
          if (hf < 1) el.style.color = "#ef4444";
          else if (hf < 1.5) el.style.color = "#f59e0b";
          else el.style.color = "#22c55e";
          const arcPct = Math.min(100, (hf / 2) * 100);
          $("#hf-arc").style.strokeDashoffset = (100 - arcPct).toFixed(1);
        }
      } else {
        ["wallet-eth", "stable-bal", "my-collateral", "pos-supplied", "pos-debt", "pos-limit", "pos-available", "pos-net"].forEach((id) => ($("#" + id).textContent = "—"));
        $("#hf-value").textContent = "—";
        $("#hf-arc").style.strokeDashoffset = "100";
      }

      startTicker();
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
      if (!silent) toast("Could not read the vault — " + (err.shortMessage || err.message || ""), "error", 9000);
    }
  }

  function setUtil(id, text) {
    const el = $("#" + id);
    if (el.textContent !== text) {
      el.textContent = text;
      el.classList.remove("bump");
      void el.offsetWidth;
      el.classList.add("bump");
    }
  }

  /* live interest ticker: debt grows at ratePerSecond between on-chain resyncs */
  function startTicker() {
    if (tickerInterval) clearInterval(tickerInterval);
    tickerInterval = setInterval(() => {
      if (!account || myDebt === 0n) return;
      myDebt += (myDebt * ratePerSecond) / ethers.parseUnits("1", 18);
      $("#pos-debt").textContent = fmtUsd(myDebt).short;
    }, 1000);
    setInterval(async () => {
      if (!account || !vaultRO) return;
      try {
        myDebt = await vaultRO.currentDebt(account);
        $("#pos-debt").textContent = fmtUsd(myDebt).short;
      } catch {}
    }, 10000);
  }

  /* ---------------- events ---------------- */

  async function refreshEvents() {
    const list = $("#ev-list");
    if (!vaultRO) {
      list.innerHTML = '<p class="muted center" style="padding:20px 0">Deploy the vault to see activity</p>';
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
        .slice(0, 12);

      if (decoded.length === 0) {
        list.innerHTML = '<p class="muted center" style="padding:20px 0">No events in the lookback window</p>';
      } else {
        list.innerHTML = decoded.map(renderEvent).join("");
      }
    } catch (err) {
      list.innerHTML = '<p class="muted center" style="padding:20px 0">Could not load events</p>';
      console.warn("events:", err);
    }
  }

  function renderEvent(ev) {
    let detail = "";
    if (ev.name === "Deposited") {
      detail = addrLink(ev.args.user) + " deposited " + fmtUnits(ev.args.amount).short + " ETH";
    } else if (ev.name === "Withdrawn") {
      detail = addrLink(ev.args.user) + " withdrew " + fmtUnits(ev.args.amount).short + " ETH";
    } else if (ev.name === "Borrowed") {
      detail = addrLink(ev.args.user) + " borrowed " + fmtUsd(ev.args.amount).short;
    } else if (ev.name === "Repaid") {
      detail = addrLink(ev.args.user) + " repaid " + fmtUsd(ev.args.amount).short;
    } else if (ev.name === "Liquidated") {
      detail = "💥 " + addrLink(ev.args.user) + " liquidated by " + addrLink(ev.args.liquidator) + " · " + fmtUsd(ev.args.debtRepaid).short + " repaid / " + fmtUnits(ev.args.collateralSeized).short + " ETH seized";
    } else if (ev.name === "Paused" || ev.name === "Unpaused") {
      detail = "vault " + (ev.name === "Paused" ? "paused 🚨" : "unpaused") + " by " + addrLink(ev.args.by);
    } else {
      detail = Object.entries(ev.args).map(([k, v]) => k + ": " + shortAddr(String(v))).join(" · ");
    }
    const tx = explorerLink("/tx/" + ev.tx);
    return (
      '<div class="ev-item" style="animation-delay:' + Math.min(ev.blockNumber % 10 * 35, 320) + 'ms">' +
      '<span class="ev-tag ev-' + ev.name + '">' + ev.name + "</span>" +
      '<span class="ev-detail mono">' + detail + "</span>" +
      '<span class="mono muted">#' + ev.blockNumber + "</span>" +
      (tx ? '<a href="' + tx + '" target="_blank" rel="noopener" class="mono" style="color:#ef4444;text-decoration:none">↗</a>' : "") +
      "</div>"
    );
  }

  /* ---------------- actions ---------------- */

  function bindUi() {
    $("#btn-connect").addEventListener("click", connect);
    $("#btn-settings").addEventListener("click", () => { $("#settings-panel").hidden = !$("#settings-panel").hidden; });
    $("#btn-cancel-settings").addEventListener("click", () => { $("#settings-panel").hidden = true; });
    $("#btn-save-settings").addEventListener("click", saveSettings);
    $("#btn-refresh-events").addEventListener("click", refreshEvents);

    $("#form-setup").addEventListener("submit", (e) => {
      e.preventDefault();
      const addr = $("#setup-address").value.trim();
      if (!ethers.isAddress(addr)) return toast("That does not look like a valid address", "error");
      vaultAddress = ethers.getAddress(addr);
      localStorage.setItem(LS_ADDRESS, vaultAddress);
      location.reload();
    });

    // deposit
    $("#btn-deposit").addEventListener("click", async () => {
      try {
        await requireVault();
        const amt = $("#deposit-amount").value;
        if (!amt || Number(amt) <= 0) return toast("Amount must be > 0", "error");
        await send(vaultRW.deposit({ value: ethers.parseEther(amt) }), "Deposited");
        $("#deposit-amount").value = "";
      } catch (err) {
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    // withdraw
    $("#btn-withdraw").addEventListener("click", async () => {
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

    // borrow
    $("#btn-borrow").addEventListener("click", async () => {
      try {
        await requireVault();
        const amt = $("#borrow-amount").value;
        if (!amt || Number(amt) <= 0) return toast("Amount must be > 0", "error");
        await send(vaultRW.borrow(ethers.parseEther(amt)), "Borrowed");
        $("#borrow-amount").value = "";
      } catch (err) {
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    // repay
    $("#btn-repay").addEventListener("click", async () => {
      try {
        await requireVault();
        const amt = $("#repay-amount").value;
        if (!amt || Number(amt) <= 0) return toast("Amount must be > 0", "error");
        const amount = ethers.parseEther(amt);
        const stableAddr = await vaultRO.stable();
        const tok = new ethers.Contract(stableAddr, ABI_S, signer);
        const allowance = await tok.allowance(account, vaultAddress);
        if (allowance < amount) {
          const ap = await tok.approve(vaultAddress, amount);
          toast("⏳ Approve submitted — " + txLink(ap.hash), "info", 12000);
          await ap.wait();
        }
        await send(vaultRW.repay(amount), "Repaid");
        $("#repay-amount").value = "";
      } catch (err) {
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    // liquidate
    $("#btn-liquidate-open").addEventListener("click", () => { $("#liq-box").hidden = !$("#liq-box").hidden; });
    $("#btn-liquidate").addEventListener("click", async () => {
      try {
        await requireVault();
        const user = $("#liq-user").value.trim();
        const amt = $("#liq-amount").value;
        if (!ethers.isAddress(user)) return toast("Invalid borrower address", "error");
        if (!amt || Number(amt) <= 0) return toast("Amount must be > 0", "error");
        const amount = ethers.parseEther(amt);
        const stableAddr = await vaultRO.stable();
        const tok = new ethers.Contract(stableAddr, ABI_S, signer);
        const allowance = await tok.allowance(account, vaultAddress);
        if (allowance < amount) {
          const ap = await tok.approve(vaultAddress, amount);
          toast("⏳ Approve submitted — " + txLink(ap.hash), "info", 12000);
          await ap.wait();
        }
        await send(vaultRW.liquidate(ethers.getAddress(user), amount), "Liquidated");
      } catch (err) {
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    // pause toggle (owner)
    $("#btn-toggle-pause").addEventListener("click", async () => {
      try {
        await requireVault();
        if (!confirm(paused ? "Unpause the vault? New deposits/borrows will be allowed again." : "Pause the vault? New deposits and borrows will be blocked (withdrawals, repayments and liquidations stay open).")) return;
        await send(vaultRW.setPaused(!paused), paused ? "Unpaused" : "Paused");
      } catch (err) {
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    // live refresh
    setInterval(() => { if (vaultRO) refreshVault(true); }, 15000);
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

  /* ---------------- boot ---------------- */

  document.addEventListener("DOMContentLoaded", init);
})();
