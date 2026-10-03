<?php
/**
 * Mawarid dApp — server-side config (optional)
 * On Hostinger this file can override js/config.js at load time
 * (only when the visitor has not saved their own address in localStorage).
 */

header("Content-Type: application/json; charset=utf-8");
header("Access-Control-Allow-Origin: *");
header("Cache-Control: no-store");

echo json_encode([
    "site"             => "Mawarid dApp",
    // Deployed on Sepolia testnet (owner: 0x319899FaAAD730519B8a2Bd72d2Eba2370a9B853).
    "registryAddress"  => "",
    "defaultChainId"   => 11155111,
    "github"           => "https://github.com/s0sta/Web3-Smart-Contract-Projects/tree/main/19-mawarid-rwa",
    "liveUrl"          => "https://s0sta.com/mawarid",
]);
