<?php
/**
 * Zakat Engine dApp — server-side config (optional)
 * On Hostinger this file can override js/config.js at load time
 * (only when the visitor has not saved their own address in localStorage).
 */

header("Content-Type: application/json; charset=utf-8");
header("Access-Control-Allow-Origin: *");
header("Cache-Control: no-store");

echo json_encode([
    "site"             => "Zakat Engine dApp",
    // Deployed on Sepolia testnet (owner: 0x319899FaAAD730519B8a2Bd72d2Eba2370a9B853).
    "engineAddress"    => "0x2B5fF4f15DdccA62233B06225b34DE5f93718495",
    "registryAddress"  => "0xc1f720413E9E166C9c81259BDDF5b3A656899989",
    "stableAddress"    => "0xA82994d07FFc62C313CF4FCeF6f6F3b68241b64c",
    "defaultChainId"   => 11155111,
    "github"           => "https://github.com/s0sta/Web3-Smart-Contract-Projects/tree/main/18-zakat-engine",
    "liveUrl"          => "https://s0sta.com/zakat",
]);
