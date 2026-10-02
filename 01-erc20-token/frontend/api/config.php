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
    // ← paste your deployed NovaToken address here, e.g. "0xAbC123…"
    "tokenAddress"  => "",
    "defaultChainId"=> 11155111, // 1 = mainnet, 11155111 = Sepolia, 31337 = anvil
    "github"        => "https://github.com/YOUR_USERNAME/web3-smart-contract-projects/tree/main/01-erc20-token",
    "liveUrl"       => "https://erc-20Token.s0sta.com",
]);
