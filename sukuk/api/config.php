<?php
/**
 * Sukuk Vault dApp — server-side config (optional)
 * On Hostinger this file can override js/config.js at load time
 * (only when the visitor has not saved their own address in localStorage).
 */

header("Content-Type: application/json; charset=utf-8");
header("Access-Control-Allow-Origin: *");
header("Cache-Control: no-store");

echo json_encode([
    "site"             => "Sukuk Vault dApp",
    // Deployed on Sepolia testnet (owner: 0x319899FaAAD730519B8a2Bd72d2Eba2370a9B853).
    "vaultAddress"     => "0xAb1b72EEA7D7842dfA48e7d44B7C21E153DA0bd7",
    "stableAddress"    => "0xD780787e1547d42191535469934599C449c10238",
    "defaultChainId"   => 11155111,
    "github"           => "https://github.com/s0sta/Web3-Smart-Contract-Projects/tree/main/15-sukuk-vault",
    "liveUrl"          => "https://s0sta.com/sukuk",
]);
