<?php
/**
 * Senate DAO dApp — server-side config (optional)
 * The frontend works fully without PHP, but on Hostinger you can set
 * the deployed governor address here and it will override js/config.js
 * at load time (only when the visitor has not saved their own
 * address in the browser's localStorage).
 */

header("Content-Type: application/json; charset=utf-8");
header("Access-Control-Allow-Origin: *");
header("Cache-Control: no-store");

echo json_encode([
    "site"            => "Senate DAO dApp",
    // Deployed on Sepolia testnet (proposer: 0x319899FaAAD730519B8a2Bd72d2Eba2370a9B853).
    "governorAddress" => "0x9a9Cb0c2Ac2A08d3A4590Aaa1B5637A16dDBcC48",
    "defaultChainId"  => 11155111, // 1 = mainnet, 11155111 = Sepolia, 31337 = anvil
    "github"          => "https://github.com/s0sta/Web3-Smart-Contract-Projects/tree/main/09-dao-governance",
    "liveUrl"         => "https://s0sta.com/dao",
]);
