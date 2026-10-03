<?php
/**
 * AMM DEX dApp — server-side config (optional)
 * The frontend works fully without PHP, but on Hostinger you can set
 * the deployed router address here and it will override js/config.js
 * at load time (only when the visitor has not saved their own
 * address in the browser's localStorage).
 */

header("Content-Type: application/json; charset=utf-8");
header("Access-Control-Allow-Origin: *");
header("Cache-Control: no-store");

echo json_encode([
    "site"          => "AMM DEX dApp",
    // Deployed on Sepolia testnet (owner: 0x319899FaAAD730519B8a2Bd72d2Eba2370a9B853).
    "routerAddress" => "0xD7C530a1025A70e1932A1554932B35317496F819",
    // The two pool tokens (the app auto-discovers the pair via the factory).
    "tokenA"        => "0xeeAa0E19Cc0734A45f99D54Ef034a3F7F2b37d3c", // GLD
    "tokenB"        => "0x2Ea88C2c86c835551a00A605A4966Ba0d755De9e", // USD
    "defaultChainId"=> 11155111, // 1 = mainnet, 11155111 = Sepolia, 31337 = anvil
    "github"        => "https://github.com/s0sta/Web3-Smart-Contract-Projects/tree/main/08-amm-dex",
    "liveUrl"       => "https://dex.s0sta.com",
]);
