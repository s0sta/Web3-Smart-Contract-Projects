/* ============================================================
   Sahm dApp — application logic
   ethers.js v6 (UMD global), no build step.
   ============================================================ */

"use strict";

(function () {
  const $ = (s) => document.querySelector(s);
  const cfg = window.APP_CONFIG || {};
  const ABI_COL = window.SAHMCOLLATERAL_ABI || [];
  const ABI_ORC = window.SAHMORACLE_ABI || [];
  const ABI_TRS = window.SAHMTREASURY_ABI || [];
  const ABI_RSK = window.SAHMRISK_ABI || [];
  const ABI_BOK = window.SAHMORDERBOOK_ABI || [];
  const ABI_AMM = window.SAHMAMM_ABI || [];
  const ABI_MRG = window.SAHMMARGIN_ABI || [];
  const ABI_GOV = window.SAHMGOVERNOR_ABI || [];
  const ABI_STB = window.SAHM_STABLE_ABI || [];

  const LS_ADDRESS = "sahm.collateralAddress";
  const LS_CHAIN = "sahm.chainId";

  const GOV_STATES = ["Review", "Voting", "Timelock", "Succeeded", "Executed", "Defeated", "Canceled"];

  /* ---------------- state ---------------- */
  let ifaceGov = null;
  let collateralAddress = localStorage.getItem(LS_ADDRESS) || cfg.collateralAddress || "";
  let chainIdPref = Number(localStorage.getItem(LS_CHAIN) || cfg.defaultChainId);
  let readProvider = null;
  let walletProvider = null;
  let signer = null;
  let account = null;
  let RO = {};
  let RW = {};
  let chainId = null;
  let rpcFailures = 0;

  const poolId = cfg.poolId || 0;

  /* ---------------- helpers ---------------- */

  function chainCfg(id) {
    return cfg.chains[id] || { name: "Unknown network", short: "unknown", rpc: null, explorer: null, currency: "ETH" };
  }
  function rpcFor(id) { return chainCfg(id).rpc || "https://ethereum-rpc.publicnode.com"; }
  function fallbackRpc(id) { return (chainCfg(id).rpcFallbacks || [])[rpcFailures % (chainCfg(id).rpcFallbacks?.length || 1)]; }
  function rebuildReadProvider() {
    const rpc = rpcFailures > 0 ? fallbackRpc(chainId ?? chainIdPref) : rpcFor(chainId ?? chainIdPref);
    readProvider = new ethers.JsonRpcProvider(rpc);
    RO.collateral = new ethers.Contract(collateralAddress, ABI_COL, readProvider);
    RO.oracle = new ethers.Contract(cfg.oracleAddress, ABI_ORC, readProvider);
    RO.treasury = new ethers.Contract(cfg.treasuryAddress, ABI_TRS, readProvider);
    RO.risk = new ethers.Contract(cfg.riskAddress, ABI_RSK, readProvider);
    RO.book = new ethers.Contract(cfg.orderBookAddress, ABI_BOK, readProvider);
    RO.amm = new ethers.Contract(cfg.ammAddress, ABI_AMM, readProvider);
    RO.margin = new ethers.Contract(cfg.marginAddress, ABI_MRG, readProvider);
    RO.governor = new ethers.Contract(cfg.governorAddress, ABI_GOV, readProvider);
    RO.stable = new ethers.Contract(cfg.stableAddress, ABI_STB, readProvider);
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
        if (data && data.collateralAddress && !localStorage.getItem(LS_ADDRESS)) collateralAddress = data.collateralAddress;
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
    collateralAddress = localStorage.getItem(LS_ADDRESS) || collateralAddress || "";

    readProvider = new ethers.JsonRpcProvider(rpcFor(chainIdPref));
    chainId = chainIdPref;

    if (collateralAddress && ethers.isAddress(collateralAddress)) {
      rebuildReadProvider();
    } else RO.collateral = null;

    $("#setup-banner").hidden = !!RO.collateral;
    $("#chain-badge").textContent = chainCfg(chainIdPref).name;
    $("#chain-badge").classList.toggle("ok", !!chainCfg(chainIdPref).rpc);
    $("#footer-address").textContent = RO.collateral ? shortAddr(collateralAddress) : "not configured";
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
    await refreshVenue();
  }

  function renderWalletButton() {
    const btn = $("#btn-connect");
    btn.textContent = account ? shortAddr(account) : "Connect Wallet";
    btn.title = account || "";
  }

  async function refreshVenue(silent) {
    if (!RO.collateral) return;
    try {
      const [price, volume, ammPrice, fees, halted] = await Promise.all([
        RO.oracle.price(cfg.stableAddress),
        RO.book.totalVolume(),
        RO.amm.quotePrice(poolId),
        RO.treasury.totalFeesCollected(),
        (await RO.risk.risks(cfg.stableAddress)).halted,
      ]);
      $("#tape-price").textContent = fmtUnits(price).short;
      $("#tape-volume").textContent = fmtUnits(volume) + " AED-S";
      $("#tape-amm").textContent = fmtUnits(ammPrice).short;
      $("#tape-fees").textContent = fmtUnits(fees) + " AED-S";
      $("#tape-halt").textContent = halted ? "⚠ HALTED" : "✓ live";

      // open orders
      let rows = "";
      let n = 0;
      try { while (true) { await RO.book.orders(n); n++; } } catch {}
      for (let i = n - 1; i >= 0 && i >= n - 10; i--) {
        const o = await RO.book.orders(i);
        if (!o.active) continue;
        rows +=
          '<div class="item-row"><span class="mono">#' + i + "</span>" +
          '<span class="small ' + (o.isBid ? "" : "muted") + '">' + (o.isBid ? "BID" : "ASK") + " " + fmtUnits(o.amount).short + " @ " + fmtUnits(o.price).short + "</span>" +
          '<span class="item-right">' + shortAddr(o.maker) + "</span>" +
          '<div class="item-actions"><button class="btn btn-ghost btn-sm" data-action="fill" data-id="' + i + '" data-bid="' + o.isBid + '">Fill all</button>' +
          '<button class="btn btn-ghost btn-sm" data-action="cancel" data-id="' + i + '">Cancel</button></div></div>';
      }
      $("#order-list").innerHTML = rows || '<p class="muted">no open orders</p>';

      // governance
      let rows2 = "";
      let pn = 0;
      try { while (true) { await RO.governor.proposals(pn); pn++; } } catch {}
      for (let i = pn - 1; i >= 0 && i >= pn - 8; i--) {
        const p = await RO.governor.proposals(i);
        const st = Number(await RO.governor.state(i));
        rows2 +=
          '<div class="item-row"><span class="mono">#' + i + "</span>" +
          '<span class="muted small">' + (p.description || "") + "</span>" +
          '<span class="item-right">' + GOV_STATES[st] + "</span>" +
          (st === 1 ? '<div class="item-actions"><button class="btn btn-ghost btn-sm" data-action="vote-for" data-id="' + i + '">For</button><button class="btn btn-ghost btn-sm" data-action="vote-against" data-id="' + i + '">Against</button></div>' : "") +
          (st === 3 ? '<div class="item-actions"><button class="btn btn-primary btn-sm" data-action="execute" data-id="' + i + '">Execute</button></div>' : "") +
          "</div>";
      }
      $("#gov-list").innerHTML = rows2 || '<p class="muted">no proposals yet</p>';

      if (account) {
        const [bal, locked] = await Promise.all([
          RO.collateral.balanceOf(account),
          RO.collateral.lockedMargin(account),
        ]);
        $("#mx-balance").textContent = fmtUnits(bal) + " AED-S";
        $("#mx-locked").textContent = fmtUnits(locked) + " AED-S";
      } else {
        $("#mx-balance").textContent = "—";
        $("#mx-locked").textContent = "—";
      }
    } catch (err) {
      console.warn("venue:", err);
      const fallbacks = chainCfg(chainId ?? chainIdPref).rpcFallbacks || [];
      if (rpcFailures < fallbacks.length) {
        rpcFailures++;
        rebuildReadProvider();
        await refreshVenue(silent);
        return;
      }
      rpcFailures = 0;
      rebuildReadProvider();
      if (!silent) toast("Could not read the venue — " + (err.shortMessage || err.message || ""), "error", 9000);
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
      collateralAddress = ethers.getAddress(addr);
      localStorage.setItem(LS_ADDRESS, collateralAddress);
      location.reload();
    });

    $("#btn-bid").addEventListener("click", async () => {
      try {
        await requireSigner();
        const price = $("#bid-price").value, amount = $("#bid-amount").value;
        if (!price || Number(price) <= 0 || !amount || Number(amount) <= 0) return toast("Price and amount must be > 0", "error");
        const cost = ethers.parseEther(amount) * ethers.parseEther(price) / 10n ** 18n;
        const allowance = await RO.stable.allowance(account, collateralAddress);
        if (allowance < cost) {
          const ap = await RO.stable.connect(signer).approve(collateralAddress, cost * 2n);
          toast("⏳ Approve submitted — " + txLink(ap.hash), "info", 12000);
          await ap.wait();
        }
        await send(RW.book.placeBid(cfg.stableAddress, ethers.parseEther(price), ethers.parseEther(amount)), "Bid placed");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-ask").addEventListener("click", async () => {
      try {
        await requireSigner();
        const price = $("#ask-price").value, amount = $("#ask-amount").value;
        if (!price || Number(price) <= 0 || !amount || Number(amount) <= 0) return toast("Price and amount must be > 0", "error");
        const allowance = await RO.stable.allowance(account, cfg.orderBookAddress);
        if (allowance < ethers.parseEther(amount)) {
          const ap = await RO.stable.connect(signer).approve(cfg.orderBookAddress, ethers.parseEther(amount) * 2n);
          toast("⏳ Approve submitted — " + txLink(ap.hash), "info", 12000);
          await ap.wait();
        }
        await send(RW.book.placeAsk(cfg.stableAddress, ethers.parseEther(price), ethers.parseEther(amount)), "Ask placed");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#order-list").addEventListener("click", async (e) => {
      const btn = e.target.closest("[data-action]");
      if (!btn) return;
      const id = BigInt(btn.dataset.id);
      try {
        await requireSigner();
        if (btn.dataset.action === "fill") {
          const o = await RO.book.orders(id);
          if (o.isBid) await send(RW.book.sell(id, o.amount), "Bid filled");
          else {
            const cost = o.amount * o.price / 10n ** 18n;
            const fee = cost * 20n / 10000n;
            const allowance = await RO.stable.allowance(account, cfg.orderBookAddress);
            if (allowance < cost + fee) {
              const ap = await RO.stable.connect(signer).approve(cfg.orderBookAddress, (cost + fee) * 2n);
              toast("⏳ Approve submitted — " + txLink(ap.hash), "info", 12000);
              await ap.wait();
            }
            await send(RW.book.buy(id, o.amount), "Ask filled");
          }
        } else await send(RW.book.cancelOrder(id), "Order canceled");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-margin-deposit").addEventListener("click", async () => {
      try {
        await requireSigner();
        const amt = $("#margin-amount").value;
        if (!amt || Number(amt) <= 0) return toast("Amount must be > 0", "error");
        const amount = ethers.parseEther(amt);
        const allowance = await RO.stable.allowance(account, collateralAddress);
        if (allowance < amount) {
          const ap = await RO.stable.connect(signer).approve(collateralAddress, amount * 2n);
          toast("⏳ Approve submitted — " + txLink(ap.hash), "info", 12000);
          await ap.wait();
        }
        await send(RW.collateral.deposit(amount), "Margin deposited");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-swap").addEventListener("click", async () => {
      try {
        await requireSigner();
        const amt = $("#swap-amount").value;
        if (!amt || Number(amt) <= 0) return toast("Amount must be > 0", "error");
        const amount = ethers.parseEther(amt);
        const allowance = await RO.stable.allowance(account, cfg.ammAddress);
        if (allowance < amount) {
          const ap = await RO.stable.connect(signer).approve(cfg.ammAddress, amount * 2n);
          toast("⏳ Approve submitted — " + txLink(ap.hash), "info", 12000);
          await ap.wait();
        }
        await send(RW.amm.swapQuoteForToken(poolId, amount, 0n), "Swapped");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-long").addEventListener("click", async () => {
      try {
        await requireSigner();
        const marginAmt = $("#long-margin").value, lev = $("#long-lev").value;
        if (!marginAmt || Number(marginAmt) <= 0) return toast("Margin must be > 0", "error");
        if (!lev || Number(lev) < 1 || Number(lev) > 500) return toast("Leverage 1–500 (bps)", "error");
        await send(RW.margin.openPosition(cfg.stableAddress, 1, ethers.parseEther(marginAmt), BigInt(lev)), "Long opened");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-propose").addEventListener("click", async () => {
      try {
        await requireSigner();
        const bps = $("#gov-fee").value;
        if (bps === "" || Number(bps) < 0 || Number(bps) > 1000) return toast("Fee must be 0–1000 bps", "error");
        const calldata = RO.amm.interface.encodeFunctionData("setFees", [Number(bps), 2000]);
        await send(RW.governor.propose(cfg.ammAddress, 0n, calldata, "Set AMM fee to " + (Number(bps) / 100).toFixed(2) + "%"), "Proposal created");
      } catch (err) { if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000); }
    });

    $("#btn-liq").addEventListener("click", async () => {
      try {
        await requireSigner();
        const tok = $("#liq-token").value, quote = $("#liq-quote").value;
        if (!tok || Number(tok) <= 0 || !quote || Number(quote) <= 0) return toast("Amounts must be > 0", "error");
        const tAmt = ethers.parseEther(tok), qAmt = ethers.parseEther(quote);
        const allowance = await RO.stable.allowance(account, cfg.ammAddress);
        if (allowance < tAmt + qAmt) {
          const ap = await RO.stable.connect(signer).approve(cfg.ammAddress, (tAmt + qAmt) * 2n);
          toast("⏳ Approve submitted — " + txLink(ap.hash), "info", 12000);
          await ap.wait();
        }
        await send(RW.amm.addLiquidity(poolId, tAmt, qAmt), "Liquidity added");
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

    setInterval(() => { if (RO.collateral) refreshVenue(); }, 30000);
  }

  async function requireSigner() {
    if (!RO.collateral || !collateralAddress) {
      const e = new Error("no collateral"); e.__handled = true;
      toast("Configure the collateral address first (Settings or the banner above)", "error");
      throw e;
    }
    if (!signer) {
      const e = new Error("no signer"); e.__handled = true;
      toast("Connect your wallet first", "error");
      throw e;
    }
    RW.collateral = new ethers.Contract(collateralAddress, ABI_COL, signer);
    RW.book = new ethers.Contract(cfg.orderBookAddress, ABI_BOK, signer);
    RW.amm = new ethers.Contract(cfg.ammAddress, ABI_AMM, signer);
    RW.margin = new ethers.Contract(cfg.marginAddress, ABI_MRG, signer);
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
    const addr = $("#set-collateral-address").value.trim();
    if (addr && !ethers.isAddress(addr)) return toast("Invalid collateral address", "error");
    if (addr) {
      collateralAddress = ethers.getAddress(addr);
      localStorage.setItem(LS_ADDRESS, collateralAddress);
    } else localStorage.removeItem(LS_ADDRESS);
    localStorage.setItem(LS_CHAIN, $("#set-chain").value);
    location.reload();
  }

  document.addEventListener("DOMContentLoaded", init);
})();
