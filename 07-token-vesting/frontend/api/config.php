<?php
/**
 * TokenVesting dApp — server-side config (optional)
 * The frontend works fully without PHP, but on Hostinger you can set
 * the deployed vesting address here and it will override js/config.js
 * at load time (only when the visitor has not saved their own
 * address in the browser's localStorage).
 */

header("Content-Type: application/json; charset=utf-8");
header("Access-Control-Allow-Origin: *");
header("Cache-Control: no-store");

echo json_encode([
    "site"          => "TokenVesting dApp",
    // Deployed on Sepolia testnet (owner: 0x319899FaAAD730519B8a2Bd72d2Eba2370a9B853).
    "vestingAddress" => "0xCf406a9b6EF721B38421eFd9860Af921E765B935",
    "defaultChainId" => 11155111, // 1 = mainnet, 11155111 = Sepolia, 31337 = anvil
    "github"        => "https://github.com/s0sta/Web3-Smart-Contract-Projects/tree/main/07-token-vesting",
    "liveUrl"       => "https://s0sta.com/vesting",
]);
