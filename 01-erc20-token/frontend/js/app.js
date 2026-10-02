/* ============================================================
   NovaToken dApp — application logic
   ethers.js v6 (UMD global), no build step, works on any static
   or PHP hosting.
   ============================================================ */

"use strict";

(function () {
  const $ = (s) => document.querySelector(s);
  const cfg = window.APP_CONFIG || {};
  const ABI = window.NOVA_TOKEN_ABI || [];

  const LS_ADDRESS = "nova.tokenAddress";
  const LS_CHAIN = "nova.chainId";

  /* ---------------- state ---------------- */
  let iface = null;
  let tokenAddress = localStorage.getItem(LS_ADDRESS) || cfg.tokenAddress || "";
  let chainIdPref = Number(localStorage.getItem(LS_CHAIN) || cfg.defaultChainId);
  let readProvider = null; // always available (public RPC)
  let walletProvider = null; // EIP-1193 when connected
  let signer = null;
  let account = null;
  let tokenRO = null; // read-only contract
  let tokenRW = null; // write contract (signer)
  let tokenMeta = { name: "NovaToken", symbol: "NOVA" };
  let owner = null;
  let chainId = null;

  /* ---------------- helpers ---------------- */

  function chainCfg(id) {
    return cfg.chains[id] || {
      name: "Unknown network",
      short: "unknown",
      rpc: null,
      explorer: null,
      currency: "ETH",
    };
  }

  function rpcFor(id) {
    const c = chainCfg(id);
    return c.rpc || "https://ethereum-rpc.publicnode.com";
  }

  function shortAddr(a) {
    if (!a) return "—";
    a = String(a);
    return a.length > 12 ? a.slice(0, 6) + "…" + a.slice(-4) : a;
  }

  function fmtAmount(bn) {
    try {
      const f = ethers.formatUnits(bn, 18);
      const n = Number(f);
      const compact =
        n >= 1e9 ? n.toExponential(2).replace("+", "") :
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
    if (!ex) return null;
    return ex + path;
  }

  function txLink(hash) {
    const base = explorerLink("/tx/" + hash);
    return base ? '<a href="' + base + '" target="_blank" rel="noopener">' + shortAddr(hash) + " ↗</a>" : shortAddr(hash);
  }

  function addrLink(addr) {
    const base = explorerLink("/address/" + addr);
    return base ? '<a href="' + base + '" target="_blank" rel="noopener">' + shortAddr(addr) + "</a>" : shortAddr(addr);
  }

  /* ---------------- toasts ---------------- */

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

  function toastTx(hash, what) {
    toast("✅ " + what + " confirmed — " + txLink(hash), "success", 9000);
  }

  function decodeError(err) {
    if (!err) return "Unknown error";
    // ethers v6.7+ may decode custom errors itself
    if (err.revert && err.revert.name) {
      const args = (err.revert.args || []).map((a) => (typeof a === "bigint" ? fmtAmount(a).short : shortAddr(String(a)))).join(", ");
      return err.revert.name + (args ? "(" + args + ")" : "");
    }
    if (err.data && iface) {
      try {
        const e = iface.parseError(err.data);
        if (e) {
          const args = e.args.map((a) => (typeof a === "bigint" ? fmtAmount(a).short : shortAddr(String(a)))).join(", ");
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
    if (err.message && err.message.includes("underlying network changed")) {
      return "Network changed — please reconnect";
    }
    return err.message || String(err);
  }

  /* ---------------- setup ---------------- */

  async function init() {
    if (typeof ethers === "undefined") {
      toast("ethers.js failed to load — check your internet connection", "error", 12000);
      return;
    }
    iface = new ethers.Interface(ABI);

    // 1. Try the PHP config endpoint first (nice on Hostinger).
    try {
      const res = await fetch("api/config.php", { cache: "no-store" });
      if (res.ok) {
        const data = await res.json();
        if (data && data.tokenAddress && !localStorage.getItem(LS_ADDRESS)) {
          tokenAddress = data.tokenAddress;
        }
        if (data && data.github) cfg.github = data.github;
      }
    } catch {}

    populateChainSelect();
    applyAddressAndChain();

    // 2. EIP-1193 wallet wiring
    if (window.ethereum) {
      walletProvider = new ethers.BrowserProvider(window.ethereum);
      window.ethereum.on("accountsChanged", onAccountsChanged);
      window.ethereum.on("chainChanged", () => window.location.reload());
      // silent reconnect
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
    tokenAddress = localStorage.getItem(LS_ADDRESS) || tokenAddress || "";

    readProvider = new ethers.JsonRpcProvider(rpcFor(chainIdPref));
    chainId = chainIdPref;

    if (tokenAddress && ethers.isAddress(tokenAddress)) {
      tokenRO = new ethers.Contract(tokenAddress, ABI, readProvider);
    } else {
      tokenRO = null;
    }
    tokenRW = null;

    $("#setup-banner").hidden = !!tokenRO;
    $("#chain-badge").textContent = chainCfg(chainIdPref).name;
    $("#chain-badge").classList.toggle("ok", !!chainCfg(chainIdPref).rpc);
    $("#hero-address").textContent = tokenRO ? tokenAddress : "not configured";
    $("#footer-address").textContent = tokenRO ? shortAddr(tokenAddress) : "not configured";
    const ex = chainCfg(chainIdPref).explorer;
    $("#link-contract").href = tokenRO && ex ? ex + "/address/" + tokenAddress : "#";
    $("#link-contract").style.display = tokenRO && ex ? "" : "none";
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
      tokenRW = null;
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
  }

  function renderWalletButton() {
    const btn = $("#btn-connect");
    if (account) {
      btn.textContent = shortAddr(account);
      btn.title = account;
    } else {
      btn.textContent = "Connect Wallet";
      btn.title = "";
    }
  }

  async function refreshStats(silent) {
    if (!tokenRO) {
      setStat("stat-total-supply", "—");
      setStat("stat-max-supply", "—");
      setStat("stat-balance", "—");
      setStat("stat-paused", "—");
      setStat("stat-owner", "—");
      setStat("stat-nonce", "—");
      return;
    }
    try {
      const [name, symbol, ts, max, paused, own] = await Promise.all([
        tokenRO.name(), tokenRO.symbol(), tokenRO.totalSupply(), tokenRO.MAX_SUPPLY(), tokenRO.paused(), tokenRO.owner(),
      ]);
      tokenMeta = { name, symbol };
      owner = own;
      $("#brand-name").textContent = name;
      $("#hero-title").innerHTML = name + " <span id=\"hero-symbol\">" + symbol + "</span>";

      setStat("stat-total-supply", fmtAmount(ts).short, fmtAmount(ts).full);
      setStat("stat-max-supply", fmtAmount(max).short, fmtAmount(max).full);
      setStat("stat-owner", shortAddr(own), own);
      setStat("stat-paused", paused ? "⛔ PAUSED" : "🟢 LIVE", paused ? "paused" : "live");

      if (account) {
        const [bal, nonce] = await Promise.all([tokenRO.balanceOf(account), tokenRO.nonces(account)]);
        setStat("stat-balance", fmtAmount(bal).short + " " + symbol, fmtAmount(bal).full);
        setStat("stat-nonce", nonce.toString(), "nonce for EIP-2612 permits");
      } else {
        setStat("stat-balance", "—", "connect your wallet");
        setStat("stat-nonce", "—");
      }

      $("#pause-status-dot").className = "dot " + (paused ? "paused" : "live");
      $("#pause-status-text").textContent = paused ? "Paused — all movement frozen" : "Live — transfers enabled";
      $("#btn-toggle-pause").textContent = paused ? "▶ Unpause" : "⏸ Pause";
      $("#pending-owner").textContent = shortAddr(await tokenRO.pendingOwner());
    } catch (err) {
      console.warn("stats:", err);
      if (!silent) {
        toast("Could not read the contract — is the address correct on this network?", "error", 9000);
      }
    }
  }

  function setStat(id, text, title) {
    const el = document.getElementById(id);
    if (!el) return;
    el.textContent = text;
    if (title) el.title = title;
  }

  function renderAdmin() {
    const section = $("#admin-section");
    const isOwner = account && owner && account.toLowerCase() === owner.toLowerCase();
    section.hidden = !isOwner;
  }

  /* ---------------- event feed ---------------- */

  async function refreshEvents() {
    const tbody = $("#activity-body");
    if (!tokenRO) {
      tbody.innerHTML = '<tr><td colspan="4" class="muted center">Deploy the token to see activity</td></tr>';
      return;
    }
    try {
      const latest = await readProvider.getBlockNumber();
      const fromBlock = Math.max(0, latest - (cfg.eventLookbackBlocks || 50000));
      const logs = await readProvider.getLogs({ address: tokenAddress, fromBlock, toBlock: latest });

      const decoded = logs
        .map((l) => {
          try {
            const parsed = iface.parseLog({ topics: l.topics, data: l.data });
            return { ...parsed, blockNumber: Number(l.blockNumber), index: Number(l.index), tx: l.transactionHash };
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
      case "Transfer":
        details =
          (ev.args.from === ethers.ZeroAddress ? "Mint → " + addrLink(ev.args.to) : addrLink(ev.args.from) + " → " + addrLink(ev.args.to)) +
          " · " + fmtAmount(ev.args.value).short + " " + tokenMeta.symbol;
        break;
      case "Approval":
        details = addrLink(ev.args.owner) + " → " + addrLink(ev.args.spender) + " · " + fmtAmount(ev.args.value).short;
        break;
      case "Minted":
        details = addrLink(ev.args.to) + " · " + fmtAmount(ev.args.amount).short + " " + tokenMeta.symbol;
        break;
      case "Burned":
        details = addrLink(ev.args.from) + " · " + fmtAmount(ev.args.amount).short + " " + tokenMeta.symbol;
        break;
      case "Paused":
      case "Unpaused":
        details = "by " + addrLink(ev.args.by);
        break;
      case "OwnershipTransferred":
        details = addrLink(ev.args.previousOwner) + " → " + addrLink(ev.args.newOwner);
        break;
      case "OwnershipTransferStarted":
        details = "pending: " + addrLink(ev.args.newOwner);
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

  /* ---------------- forms & actions ---------------- */

  function bindUi() {
    $("#btn-connect").addEventListener("click", connect);
    $("#btn-settings").addEventListener("click", () => { $("#settings-panel").hidden = !$("#settings-panel").hidden; });
    $("#btn-cancel-settings").addEventListener("click", () => { $("#settings-panel").hidden = true; });
    $("#btn-save-settings").addEventListener("click", saveSettings);
    $("#btn-copy-address").addEventListener("click", copyAddress);
    $("#btn-refresh-events").addEventListener("click", refreshEvents);
    $("#btn-toggle-pause").addEventListener("click", togglePause);
    $("#btn-accept-ownership").addEventListener("click", acceptOwnership);
    $("#btn-renounce").addEventListener("click", renounceOwnership);

    $("#form-setup").addEventListener("submit", (e) => {
      e.preventDefault();
      const addr = $("#setup-address").value.trim();
      if (!ethers.isAddress(addr)) return toast("That does not look like a valid address", "error");
      tokenAddress = ethers.getAddress(addr);
      localStorage.setItem(LS_ADDRESS, tokenAddress);
      location.reload();
    });

    // token actions
    bindAction("form-transfer", async () => {
      await requireToken();
      const to = getAddress("transfer-to");
      const amount = getAmount("transfer-amount");
      await send(tokenRW.transfer(to, amount), "Transfer");
    });
    bindAction("form-approve", async () => {
      await requireToken();
      const spender = getAddress("approve-spender");
      const amount = getAmount("approve-amount");
      await send(tokenRW.approve(spender, amount), "Approve");
    });
    bindAction("form-transfer-from", async () => {
      await requireToken();
      const from = getAddress("tf-from");
      const to = getAddress("tf-to");
      const amount = getAmount("tf-amount");
      await send(tokenRW.transferFrom(from, to, amount), "TransferFrom");
    });
    bindAction("form-burn", async () => {
      await requireToken();
      const amount = getAmount("burn-amount");
      await send(tokenRW.burn(amount), "Burn");
    });
    bindAction("form-burn-from", async () => {
      await requireToken();
      const acc = getAddress("bf-account");
      const amount = getAmount("bf-amount");
      await send(tokenRW.burnFrom(acc, amount), "BurnFrom");
    });
    bindAction("form-permit", submitPermit);
    bindAction("form-mint", async () => {
      await requireToken();
      const to = getAddress("mint-to");
      const amount = getAmount("mint-amount");
      await send(tokenRW.mint(to, amount), "Mint");
    });
    bindAction("form-transfer-ownership", async () => {
      await requireToken();
      const newOwner = getAddress("to-new-owner");
      await send(tokenRW.transferOwnership(newOwner), "Ownership nomination");
    });

    // read-only checks (work without a wallet)
    $("#form-balance-of").addEventListener("submit", async (e) => {
      e.preventDefault();
      if (!tokenRO) return toast("Configure a token address first", "error");
      const a = $("#bo-address").value.trim();
      if (!ethers.isAddress(a)) return toast("Invalid address", "error");
      const bal = await tokenRO.balanceOf(a);
      const f = fmtAmount(bal);
      $("#result-balance").textContent = f.short + " " + tokenMeta.symbol + "  (" + f.full + ")";
    });
    $("#form-allowance-of").addEventListener("submit", async (e) => {
      e.preventDefault();
      if (!tokenRO) return toast("Configure a token address first", "error");
      const o = $("#ao-owner").value.trim();
      const s = $("#ao-spender").value.trim();
      if (!ethers.isAddress(o) || !ethers.isAddress(s)) return toast("Invalid address", "error");
      const al = await tokenRO.allowance(o, s);
      const f = fmtAmount(al);
      $("#result-allowance").textContent = f.short + " " + tokenMeta.symbol + "  (" + f.full + ")";
    });

    // live refresh (silent — no toast spam on background errors)
    setInterval(() => { if (tokenRO) refreshStats(true); }, 15000);
  }

  function bindAction(formId, handler) {
    const form = $(formId);
    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      const btn = form.querySelector('button[type="submit"]');
      const original = btn.textContent;
      btn.disabled = true;
      btn.innerHTML = '<span class="spin">◌</span> Pending…';
      try {
        await handler();
      } catch (err) {
        if (err && err.__handled) return; // already toasted
        toast("⚠ " + decodeError(err), "error", 9000);
      } finally {
        btn.disabled = false;
        btn.textContent = original;
      }
    });
  }

  function getAddress(id) {
    const v = $(id).value.trim();
    if (!ethers.isAddress(v)) throw new Error("Invalid address");
    return ethers.getAddress(v);
  }

  function getAmount(id) {
    const v = $(id).value;
    if (!v || Number(v) <= 0) throw new Error("Amount must be > 0");
    try {
      return ethers.parseUnits(v, 18);
    } catch {
      throw new Error("Invalid amount — max 18 decimals");
    }
  }

  async function requireToken() {
    if (!tokenRO || !tokenAddress) {
      const e = new Error("Configure a token address first (Settings or the banner above)");
      e.__handled = true;
      toast("Configure a token address first", "error");
      throw e;
    }
    if (!signer) {
      const e = new Error("Connect your wallet first");
      e.__handled = true;
      toast("Connect your wallet first", "error");
      throw e;
    }
    if (!tokenRW) tokenRW = new ethers.Contract(tokenAddress, ABI, signer);
  }

  async function send(txPromise, label) {
    const tx = await txPromise;
    toast("⏳ " + label + " submitted — " + txLink(tx.hash), "info", 12000);
    await tx.wait();
    toastTx(tx.hash, label);
    await refreshStats();
    await refreshEvents();
    renderAdmin();
  }

  /* ---------------- EIP-2612 permit ---------------- */

  async function submitPermit() {
    await requireToken();
    const spender = getAddress("permit-spender");
    const value = getAmount("permit-value");
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600); // +1 hour

    const nonce = await tokenRO.nonces(account);
    const network = await walletProvider.getNetwork();
    const domain = {
      name: tokenMeta.name,
      version: "1",
      chainId: Number(network.chainId),
      verifyingContract: tokenAddress,
    };
    const types = {
      Permit: [
        { name: "owner", type: "address" },
        { name: "spender", type: "address" },
        { name: "value", type: "uint256" },
        { name: "nonce", type: "uint256" },
        { name: "deadline", type: "uint256" },
      ],
    };
    const message = { owner: account, spender, value, nonce: BigInt(nonce), deadline };

    toast("✍ Sign the permit in your wallet…", "info", 12000);
    const signature = await signer.signTypedData(domain, types, message);
    const sig = ethers.Signature.from(signature);

    if (!tokenRW) tokenRW = new ethers.Contract(tokenAddress, ABI, signer);
    await send(tokenRW.permit(account, spender, value, deadline, sig.v, sig.r, sig.s), "Permit");
  }

  /* ---------------- admin ---------------- */

  async function togglePause() {
    try {
      await requireToken();
      const paused = await tokenRO.paused();
      await send(paused ? tokenRW.unpause() : tokenRW.pause(), paused ? "Unpause" : "Pause");
    } catch (err) {
      if (!(err && err.__handled)) toast("⚠ " + decodeError(err), "error", 9000);
    }
  }

  async function acceptOwnership() {
    try {
      await requireToken();
      await send(tokenRW.acceptOwnership(), "Accept ownership");
    } catch (err) {
      if (!(err && err.__handled)) toast("⚠ " + decodeError(err), "error", 9000);
    }
  }

  async function renounceOwnership() {
    try {
      await requireToken();
      if (!confirm("Renouncing ownership is IRREVERSIBLE — mint/pause/ownership controls will be locked forever. Continue?")) return;
      await send(tokenRW.renounceOwnership(), "Renounce ownership");
    } catch (err) {
      if (!(err && err.__handled)) toast("⚠ " + decodeError(err), "error", 9000);
    }
  }

  /* ---------------- settings ---------------- */

  function saveSettings() {
    const addr = $("#set-token-address").value.trim();
    if (addr && !ethers.isAddress(addr)) return toast("Invalid token address", "error");
    if (addr) {
      tokenAddress = ethers.getAddress(addr);
      localStorage.setItem(LS_ADDRESS, tokenAddress);
    } else {
      localStorage.removeItem(LS_ADDRESS);
    }
    const chain = $("#set-chain").value;
    localStorage.setItem(LS_CHAIN, chain);
    location.reload();
  }

  function copyAddress() {
    if (!tokenAddress) return;
    navigator.clipboard.writeText(tokenAddress).then(
      () => toast("Address copied to clipboard", "success"),
      () => toast("Copy failed — address: " + tokenAddress, "info", 9000)
    );
  }

  /* ---------------- boot ---------------- */

  document.addEventListener("DOMContentLoaded", init);
})();
