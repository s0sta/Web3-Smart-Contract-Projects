<?php
/**
 * Takaful dApp — server-side config (optional)
 * On Hostinger this file can override js/config.js at load time
 * (only when the visitor has not saved their own address in localStorage).
 */

header("Content-Type: application/json; charset=utf-8");
header("Access-Control-Allow-Origin: *");
header("Cache-Control: no-store");

echo json_encode([
    "site"             => "Takaful dApp",
    // Deployed on Sepolia testnet (owner: 0x319899FaAAD730519B8a2Bd72d2Eba2370a9B853).
    "poolAddress"      => "0xe0528967d4bB5C4Ccd02d64cEa3b7D57367dA238",
    "stableAddress"    => "0xf720e2F1C79566e5C1043ea877d442eB348E6e28",
    "defaultChainId"   => 11155111,
    "github"           => "https://github.com/s0sta/Web3-Smart-Contract-Projects/tree/main/16-takaful-insurance",
    "liveUrl"          => "https://s0sta.com/takaful",
]);
