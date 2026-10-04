<?php
/**
 * Murabaha dApp — server-side config (optional)
 * On Hostinger this file can override js/config.js at load time
 * (only when the visitor has not saved their own address in localStorage).
 */

header("Content-Type: application/json; charset=utf-8");
header("Access-Control-Allow-Origin: *");
header("Cache-Control: no-store");

echo json_encode([
    "site"             => "Murabaha dApp",
    // Deployed on Sepolia testnet (owner: 0x319899FaAAD730519B8a2Bd72d2Eba2370a9B853).
    "bookAddress"      => "0xa293EBb6e86718f5A2E9c53403E38f698824e751",
    "stableAddress"    => "0x6aE582006619EacBa5D221275C75B022bdac7BC8",
    "defaultChainId"   => 11155111,
    "github"           => "https://github.com/s0sta/Web3-Smart-Contract-Projects/tree/main/17-murabaha-finance",
    "liveUrl"          => "https://s0sta.com/murabaha",
]);
