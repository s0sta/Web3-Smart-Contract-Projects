<?php
/**
 * JOP Owners Association dApp — server-side config (optional)
 * The frontend works fully without PHP, but on Hostinger you can set
 * the deployed governor address here and it will override js/config.js
 * at load time (only when the visitor has not saved their own
 * address in the browser's localStorage).
 */

header("Content-Type: application/json; charset=utf-8");
header("Access-Control-Allow-Origin: *");
header("Cache-Control: no-store");

echo json_encode([
    "site"             => "JOP Owners Association dApp",
    // Deployed on Sepolia testnet (owner: 0x319899FaAAD730519B8a2Bd72d2Eba2370a9B853).
    "governorAddress"  => "0xFeD940A0435816f3f190f99737676F6A62Ba4228",
    "defaultChainId"   => 11155111,
    "github"           => "https://github.com/s0sta/Web3-Smart-Contract-Projects/tree/main/11-owners-association",
    "liveUrl"          => "https://s0sta.com/hoa",
]);
