<?php
/**
 * NovaToken dApp — server-side config (optional)
 * -------------------------------------------------
 * The frontend works fully without PHP, but on Hostinger you can set
 * the deployed token address here and it will override js/config.js
 * at load time (only when the visitor has not saved their own
 * address in the browser's localStorage).
 *
 * Just paste your deployed NovaToken address below.
 */

header("Content-Type: application/json; charset=utf-8");
header("Access-Control-Allow-Origin: *");
header("Cache-Control: no-store");

echo json_encode([
    "site"          => "NovaToken dApp",
    // Deployed on Sepolia testnet (owner: 0x319899FaAAD730519B8a2Bd72d2Eba2370a9B853).
    "tokenAddress"  => "0x26b420683E6F6Df39CFceBd7C5bB78B7459b8B62",
    "defaultChainId"=> 11155111, // 1 = mainnet, 11155111 = Sepolia, 31337 = anvil
    "github"        => "https://github.com/s0sta/Web3-Smart-Contract-Projects/tree/main/01-erc20-token",
    "liveUrl"       => "https://s0sta.com/erc20-token",
]);
