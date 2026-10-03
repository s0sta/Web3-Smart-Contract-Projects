/* ============================================================
   Genesis Collection dApp — application logic
   ethers.js v6 (UMD global), no build step.
   ============================================================ */

"use strict";

(function () {
  const $ = (s) => document.querySelector(s);
  const cfg = window.APP_CONFIG || {};
  const ABI = window.GENESIS_NFT_ABI || [];

  const LS_ADDRESS = "nft.nftAddress";
  const LS_CHAIN = "nft.chainId";

  const PHASES = ["Closed", "Whitelist", "Public"];

  /* ---------------- state ---------------- */
  let ifaceN = null;
  let nftAddress = localStorage.getItem(LS_ADDRESS) || cfg.nftAddress || "";
  let chainIdPref = Number(localStorage.getItem(LS_CHAIN) || cfg.defaultChainId);
  let readProvider = null;
  let walletProvider = null;
  let signer = null;
  let account = null;
  let nftRO = null;
  let nftRW = null;
  let nftOwner = null;
  let chainId = null;

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
      return { short: f.replace(/\.?0+$/, ""), full: f };
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

  function toIpfsUrl(uri) {
    if (!uri) return null;
    if (uri.startsWith("ipfs://")) return cfg.ipfsGateway + uri.slice(7);
    return uri;
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
    if (err.data && ifaceN) {
      try {
        const e = ifaceN.parseError(err.data);
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

  function spawnStars() {
    const box = $("#stars");
    for (let i = 0; i < 26; i++) {
      const s = document.createElement("i");
      s.style.left = Math.random() * 100 + "%";
      s.style.top = Math.random() * 100 + "%";
      s.style.setProperty("--d", 2.5 + Math.random() * 5 + "s");
      s.style.animationDelay = Math.random() * 6 + "s";
      box.appendChild(s);
    }
  }

  async function init() {
    if (typeof ethers === "undefined") {
      toast("ethers.js failed to load — check your internet connection", "error", 12000);
      return;
    }
    ifaceN = new ethers.Interface(ABI);
    spawnStars();

    try {
      const res = await fetch("api/config.php", { cache: "no-store" });
      if (res.ok) {
        const data = await res.json();
        if (data && data.nftAddress && !localStorage.getItem(LS_ADDRESS)) {
          nftAddress = data.nftAddress;
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
    nftAddress = localStorage.getItem(LS_ADDRESS) || nftAddress || "";

    readProvider = new ethers.JsonRpcProvider(rpcFor(chainIdPref));
    chainId = chainIdPref;

    if (nftAddress && ethers.isAddress(nftAddress)) {
      nftRO = new ethers.Contract(nftAddress, ABI, readProvider);
    } else {
      nftRO = null;
    }
    nftRW = null;

    $("#setup-banner").hidden = !!nftRO;
    $("#chain-badge").textContent = chainCfg(chainIdPref).name;
    $("#chain-badge").classList.toggle("ok", !!chainCfg(chainIdPref).rpc);
    $("#hero-address").textContent = nftRO ? nftAddress : "not configured";
    $("#footer-address").textContent = nftRO ? shortAddr(nftAddress) : "not configured";
    const ex = chainCfg(chainIdPref).explorer;
    $("#link-contract").href = nftRO && ex ? ex + "/address/" + nftAddress : "#";
    $("#link-contract").style.display = nftRO && ex ? "" : "none";
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
      nftRW = null;
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
    await refreshGallery();
    await refreshEvents();
    renderAdmin();
  }

  function renderWalletButton() {
    const btn = $("#btn-connect");
    btn.textContent = account ? shortAddr(account) : "Connect Wallet";
    btn.title = account || "";
  }

  async function refreshStats(silent) {
    if (!nftRO) {
      ["stat-supply", "stat-max", "stat-phase", "stat-revealed", "stat-royalty", "stat-balance"].forEach((id) => ($("#" + id).textContent = "—"));
      return;
    }
    try {
      const [supply, max, phase, revealed, royaltyRecipient, royaltyBps, owner, myBal, wp, wcap, pp, pcap] =
        await Promise.all([
          nftRO.totalSupply(), nftRO.MAX_SUPPLY(), nftRO.phase(), nftRO.revealed(),
          nftRO.royaltyRecipient(), nftRO.royaltyBps(), nftRO.owner(),
          account ? nftRO.balanceOf(account) : Promise.resolve(0n),
          nftRO.WHITELIST_PRICE(), nftRO.WHITELIST_MAX_PER_WALLET(), nftRO.PUBLIC_PRICE(), nftRO.PUBLIC_MAX_PER_WALLET(),
        ]);
      nftOwner = owner;
      const ph = PHASES[Number(phase)];

      $("#stat-supply").textContent = supply.toString() + " / " + max.toString();
      $("#stat-max").textContent = max.toString();
      $("#stat-phase").textContent = ph;
      $("#stat-phase").className = "stat-value phase-badge phase-" + ph;
      $("#stat-revealed").textContent = revealed ? "✅ revealed" : "🔒 hidden";
      $("#stat-royalty").textContent = (Number(royaltyBps) / 100).toFixed(1) + "% → " + shortAddr(royaltyRecipient);
      $("#stat-balance").textContent = account ? myBal.toString() : "—";

      $("#public-price").textContent = fmtEth(pp).short + " ETH";
      $("#public-cap").textContent = pcap.toString();
      $("#wl-price").textContent = fmtEth(wp).short + " ETH";
      $("#wl-cap").textContent = wcap.toString();

      $("#reveal-status").textContent = revealed ? "revealed — base URI + id + .json" : "pre-reveal placeholder live";
      $("#btn-reveal").textContent = revealed ? "Hide (un-reveal)" : "Reveal";
    } catch (err) {
      console.warn("stats:", err);
      if (!silent) toast("Could not read the collection — is the address correct on this network?", "error", 9000);
    }
  }

  async function refreshGallery() {
    const box = $("#gallery");
    if (!nftRO) {
      box.innerHTML = '<div class="card center muted" style="grid-column: 1 / -1">Deploy the collection to see the gallery</div>';
      return;
    }
    try {
      const latest = await readProvider.getBlockNumber();
      const fromBlock = Math.max(0, latest - (cfg.eventLookbackBlocks || 50000));
      const logs = await readProvider.getLogs({
        address: nftAddress,
        topics: [ifaceN.getEvent("Transfer").topicHash],
        fromBlock,
        toBlock: latest,
      });
      const parsed = logs
        .map((l) => {
          try { return ifaceN.parseLog({ topics: l.topics, data: l.data }); } catch { return null; }
        })
        .filter(Boolean)
        .sort((a, b) => (Number(b.blockNumber) - Number(a.blockNumber)) || (Number(b.index) - Number(a.index)));

      // unique token ids, latest first, cap at 12
      const seen = new Set();
      const ids = [];
      for (const p of parsed) {
        const id = Number(p.args.tokenId);
        if (!seen.has(id)) {
          seen.add(id);
          ids.push(id);
          if (ids.length === 12) break;
        }
      }

      $("#gallery-note").textContent = ids.length
        ? "showing " + ids.length + " recent mints"
        : "(no mints in the lookback window)";

      if (ids.length === 0) {
        box.innerHTML = '<div class="card center muted" style="grid-column: 1 / -1">No mints yet — mint one above 🎨</div>';
        return;
      }

      box.innerHTML = "";
      ids.forEach((id, i) => box.appendChild(buildTile(id, i)));
    } catch (err) {
      console.warn("gallery:", err);
      box.innerHTML = '<div class="card center muted" style="grid-column: 1 / -1">Could not load the gallery</div>';
    }
  }

  function buildTile(tokenId, i) {
    const tile = document.createElement("div");
    tile.className = "tile";
    tile.style.animationDelay = Math.min(i * 60, 360) + "ms";

    const idBadge = document.createElement("span");
    idBadge.className = "tile-id";
    idBadge.textContent = "#" + tokenId;
    tile.appendChild(idBadge);

    // placeholder until metadata loads (or when pre-reveal)
    const ph = document.createElement("div");
    ph.className = "ph";
    ph.textContent = "#" + tokenId;
    tile.appendChild(ph);

    tile.addEventListener("click", () => {
      const os = "https://testnets.opensea.io/assets/sepolia/" + nftAddress + "/" + tokenId;
      window.open(os, "_blank", "noopener");
    });

    // try to resolve real metadata + image
    nftRO.tokenURI(tokenId)
      .then(async (uri) => {
        if (!uri) return;
        const jsonUrl = toIpfsUrl(uri);
        if (!jsonUrl) return;
        const res = await fetch(jsonUrl, { mode: "cors" });
        if (!res.ok) return;
        const meta = await res.json();
        const imgUrl = toIpfsUrl(meta.image || meta.image_url);
        if (!imgUrl) return;
        const img = document.createElement("img");
        img.src = imgUrl;
        img.alt = meta.name || "#" + tokenId;
        img.onload = () => {
          ph.remove();
          tile.prepend(img);
          tile.classList.add("flash");
        };
        img.onerror = () => {};
      })
      .catch(() => {
        // pre-reveal or unreachable metadata → locked look
        const lock = document.createElement("div");
        lock.className = "locked";
        lock.textContent = "🔒";
        tile.appendChild(lock);
      });

    return tile;
  }

  function renderAdmin() {
    const isOwner = account && nftOwner && account.toLowerCase() === nftOwner.toLowerCase();
    $("#admin-section").hidden = !isOwner;
  }

  /* ---------------- event feed ---------------- */

  async function refreshEvents() {
    const tbody = $("#activity-body");
    if (!nftRO) {
      tbody.innerHTML = '<tr><td colspan="4" class="muted center">Deploy the collection to see activity</td></tr>';
      return;
    }
    try {
      const latest = await readProvider.getBlockNumber();
      const fromBlock = Math.max(0, latest - (cfg.eventLookbackBlocks || 50000));
      const logs = await readProvider.getLogs({ address: nftAddress, fromBlock, toBlock: latest });
      const decoded = logs
        .map((l) => {
          try {
            return { ...ifaceN.parseLog({ topics: l.topics, data: l.data }), blockNumber: Number(l.blockNumber), index: Number(l.index), tx: l.transactionHash };
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
        details = ev.args.from === ethers.ZeroAddress
          ? "🎨 mint #" + ev.args.tokenId + " → " + addrLink(ev.args.to)
          : addrLink(ev.args.from) + " → " + addrLink(ev.args.to) + " · #" + ev.args.tokenId;
        break;
      case "PhaseChanged":
        details = "phase → " + PHASES[Number(ev.args.newPhase)];
        break;
      case "MerkleRootSet":
        details = "whitelist root set: " + shortAddr(ev.args.root);
        break;
      case "Revealed":
        details = "revealed = " + ev.args.revealed;
        break;
      case "RoyaltySet":
        details = "royalty " + (Number(ev.args.bps) / 100).toFixed(1) + "% → " + addrLink(ev.args.recipient);
        break;
      case "Withdrawn":
        details = fmtEth(ev.args.amount).short + " ETH → " + addrLink(ev.args.to);
        break;
      case "ApprovalForAll":
        details = addrLink(ev.args.owner) + " operator " + addrLink(ev.args.operator);
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

  function parseProof(text) {
    return text
      .split(/[\s,]+/)
      .filter(Boolean)
      .map((h) => (h.startsWith("0x") ? h : "0x" + h));
  }

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
      nftAddress = ethers.getAddress(addr);
      localStorage.setItem(LS_ADDRESS, nftAddress);
      location.reload();
    });

    // public mint
    $("#form-mint-public").addEventListener("submit", async (e) => {
      e.preventDefault();
      try {
        await requireNft();
        const qty = $("#mint-qty").value;
        if (!qty || Number(qty) < 1) return toast("Quantity must be ≥ 1", "error");
        const price = await nftRO.PUBLIC_PRICE();
        await send(nftRW.mintPublic(qty, { value: price * BigInt(qty) }), "Minted " + qty + " NFT" + (qty > 1 ? "s" : ""));
        $("#mint-qty").value = "";
      } catch (err) {
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    // whitelist mint
    $("#form-mint-wl").addEventListener("submit", async (e) => {
      e.preventDefault();
      try {
        await requireNft();
        const qty = $("#wl-qty").value;
        if (!qty || Number(qty) < 1) return toast("Quantity must be ≥ 1", "error");
        const proof = parseProof($("#wl-proof").value);
        for (const p of proof) {
          if (!ethers.isHexString(p, 32)) return toast("Every proof line must be a 32-byte hex hash", "error");
        }
        if (proof.length === 0) return toast("Paste your Merkle proof first", "error");
        const price = await nftRO.WHITELIST_PRICE();
        await send(nftRW.mintWhitelist(proof, qty, { value: price * BigInt(qty) }), "Whitelist minted");
      } catch (err) {
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    // admin: phase
    $("#form-phase").addEventListener("submit", async (e) => {
      e.preventDefault();
      try {
        await requireNft();
        await send(nftRW.setPhase($("#phase-select").value), "Phase set");
      } catch (err) {
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    // admin: merkle root
    $("#form-root").addEventListener("submit", async (e) => {
      e.preventDefault();
      try {
        await requireNft();
        const root = $("#root-input").value.trim();
        if (!ethers.isHexString(root, 32)) return toast("Root must be 32-byte hex", "error");
        await send(nftRW.setMerkleRoot(root), "Merkle root set");
        $("#root-input").value = "";
      } catch (err) {
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    // admin: reveal toggle
    $("#btn-reveal").addEventListener("click", async () => {
      try {
        await requireNft();
        const revealed = await nftRO.revealed();
        await send(nftRW.setRevealed(!revealed), revealed ? "Un-revealed" : "Revealed");
      } catch (err) {
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    // admin: URIs
    $("#form-uri").addEventListener("submit", async (e) => {
      e.preventDefault();
      try {
        await requireNft();
        const base = $("#base-uri").value.trim();
        const pre = $("#prereveal-uri").value.trim();
        if (base) await send(nftRW.setBaseURI(base), "Base URI set");
        if (pre) await send(nftRW.setPrerevealURI(pre), "Pre-reveal URI set");
        if (!base && !pre) toast("Enter a base URI or pre-reveal URI", "info");
      } catch (err) {
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    // admin: royalty
    $("#form-royalty").addEventListener("submit", async (e) => {
      e.preventDefault();
      try {
        await requireNft();
        const rec = $("#royalty-recipient").value.trim();
        const bps = $("#royalty-bps").value;
        if (!ethers.isAddress(rec)) return toast("Invalid recipient", "error");
        if (bps === "" || Number(bps) < 0 || Number(bps) > 1000) return toast("Bps must be 0–1000", "error");
        await send(nftRW.setRoyalty(ethers.getAddress(rec), bps), "Royalty set");
      } catch (err) {
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    // admin: reserve mint
    $("#form-owner-mint").addEventListener("submit", async (e) => {
      e.preventDefault();
      try {
        await requireNft();
        const to = $("#om-recipient").value.trim();
        const qty = $("#om-qty").value;
        if (!ethers.isAddress(to)) return toast("Invalid recipient", "error");
        if (!qty || Number(qty) < 1) return toast("Quantity must be ≥ 1", "error");
        await send(nftRW.ownerMint(ethers.getAddress(to), qty), "Reserve minted");
      } catch (err) {
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    // admin: withdraw
    $("#btn-withdraw").addEventListener("click", async () => {
      try {
        await requireNft();
        await send(nftRW.withdraw(), "Withdrawn");
      } catch (err) {
        if (!err.__handled) toast("⚠ " + decodeError(err), "error", 9000);
      }
    });

    // live refresh
    setInterval(() => { if (nftRO) refreshStats(true); }, 15000);
  }

  async function requireNft() {
    if (!nftRO || !nftAddress) {
      const e = new Error("Configure the collection address first");
      e.__handled = true;
      toast("Configure the collection address first (Settings or the banner above)", "error");
      throw e;
    }
    if (!signer) {
      const e = new Error("Connect your wallet first");
      e.__handled = true;
      toast("Connect your wallet first", "error");
      throw e;
    }
    if (!nftRW) nftRW = new ethers.Contract(nftAddress, ABI, signer);
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
    const addr = $("#set-nft-address").value.trim();
    if (addr && !ethers.isAddress(addr)) return toast("Invalid collection address", "error");
    if (addr) {
      nftAddress = ethers.getAddress(addr);
      localStorage.setItem(LS_ADDRESS, nftAddress);
    } else {
      localStorage.removeItem(LS_ADDRESS);
    }
    localStorage.setItem(LS_CHAIN, $("#set-chain").value);
    location.reload();
  }

  function copyAddress() {
    if (!nftAddress) return;
    navigator.clipboard.writeText(nftAddress).then(
      () => toast("Address copied to clipboard", "success"),
      () => toast("Copy failed — address: " + nftAddress, "info", 9000)
    );
  }

  /* ---------------- boot ---------------- */

  document.addEventListener("DOMContentLoaded", init);
})();
