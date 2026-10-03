<?php
/**
 * TrustEscrow dApp — server-side config (optional)
 * The frontend works fully without PHP, but on Hostinger you can set
 * the deployed escrow address here and it will override js/config.js
 * at load time (only when the visitor has not saved their own
 * address in the browser's localStorage).
 */

header("Content-Type: application/json; charset=utf-8");
header("Access-Control-Allow-Origin: *");
header("Cache-Control: no-store");

echo json_encode([
    "site"          => "TrustEscrow dApp",
    // Deployed on Sepolia testnet (owner: 0x319899FaAAD730519B8a2Bd72d2Eba2370a9B853).
    "escrowAddress" => "0xC1b5B1dcd8985c9965C2E7Ac8E4A1a3b85394564",
    "defaultChainId"=> 11155111, // 1 = mainnet, 11155111 = Sepolia, 31337 = anvil
    "github"        => "https://github.com/s0sta/Web3-Smart-Contract-Projects/tree/main/04-escrow-service",
    "liveUrl"       => "https://s0sta.com/escrow",
]);
