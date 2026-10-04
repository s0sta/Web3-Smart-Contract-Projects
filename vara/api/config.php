<?php
/**
 * VARA Treasury dApp — server-side config (optional)
 * On Hostinger this file can override js/config.js at load time
 * (only when the visitor has not saved their own address in localStorage).
 */

header("Content-Type: application/json; charset=utf-8");
header("Access-Control-Allow-Origin: *");
header("Cache-Control: no-store");

echo json_encode([
    "site"             => "VARA Treasury dApp",
    // Deployed on Sepolia testnet (owner: 0x319899FaAAD730519B8a2Bd72d2Eba2370a9B853).
    "treasuryAddress"  => "0xfB14587cd6bd501Ac4e53b65904D08d597950818",
    "complianceAddress" => "0x4004F66b57fFA0a20345Eb065e8E9Cd371Ff15BF",
    "stableAddress"    => "0x2dCAffe71EBb29BB7EFEa9D9acE27Db830B53Bd7",
    "defaultChainId"   => 11155111,
    "github"           => "https://github.com/s0sta/Web3-Smart-Contract-Projects/tree/main/14-vara-treasury",
    "liveUrl"          => "https://s0sta.com/vara",
]);
