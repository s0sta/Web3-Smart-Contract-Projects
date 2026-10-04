<?php
/**
 * CrowdFund dApp — server-side config (optional)
 * -------------------------------------------------
 * The frontend works fully without PHP, but on Hostinger you can set
 * the deployed factory address here and it will override js/config.js
 * at load time (only when the visitor has not saved their own
 * address in the browser's localStorage).
 */

header("Content-Type: application/json; charset=utf-8");
header("Access-Control-Allow-Origin: *");
header("Cache-Control: no-store");

echo json_encode([
    "site"          => "CrowdFund dApp",
    // Deployed on Sepolia testnet (owner: 0x319899FaAAD730519B8a2Bd72d2Eba2370a9B853).
    "factoryAddress"=> "0x49Ed445AB73b0397B8946c6BCDCa4bFcF04C9FdB",
    "defaultChainId"=> 11155111, // 1 = mainnet, 11155111 = Sepolia, 31337 = anvil
    "github"        => "https://github.com/s0sta/Web3-Smart-Contract-Projects/tree/main/02-crowdfunding",
    "liveUrl"       => "https://s0sta.com/crowdfund",
]);
