<?php
/**
 * Waqf Endowment dApp — server-side config (optional)
 * On Hostinger this file can override js/config.js at load time
 * (only when the visitor has not saved their own address in localStorage).
 */

header("Content-Type: application/json; charset=utf-8");
header("Access-Control-Allow-Origin: *");
header("Cache-Control: no-store");

echo json_encode([
    "site"             => "Waqf Endowment dApp",
    // Deployed on Sepolia testnet (owner: 0x319899FaAAD730519B8a2Bd72d2Eba2370a9B853).
    "vaultAddress"     => "0x3dc6d47de5f14f562b4bee02417d2fa51cab1c19",
    "governorAddress"  => "0xa2def9668265bca1b6ad0b928f6aa00658d18c15",
    "registryAddress"  => "0x368923bf9dbd5a15f67626154104f4b2d70f6555",
    "stableAddress"    => "0x81fc34aa5568aaf97b116048473411f532bd83b9",
    "defaultChainId"   => 11155111,
    "github"           => "https://github.com/s0sta/Web3-Smart-Contract-Projects/tree/main/13-waqf-endowment",
    "liveUrl"          => "https://s0sta.com/waqf",
]);
