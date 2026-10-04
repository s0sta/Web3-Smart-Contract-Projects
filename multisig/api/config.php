<?php
/**
 * MultiSig Vault dApp — server-side config (optional)
 * The frontend works fully without PHP, but on Hostinger you can set
 * the deployed wallet address here and it will override js/config.js
 * at load time (only when the visitor has not saved their own
 * address in the browser's localStorage).
 */

header("Content-Type: application/json; charset=utf-8");
header("Access-Control-Allow-Origin: *");
header("Cache-Control: no-store");

echo json_encode([
    "site"          => "MultiSig Vault dApp",
    // Deployed on Sepolia testnet — 2-of-3, owner1 = 0x319899FaAAD730519B8a2Bd72d2Eba2370a9B853.
    "walletAddress" => "0x07212677caE6aa93331d6E18205EB5898c3079f4",
    "defaultChainId"=> 11155111, // 1 = mainnet, 11155111 = Sepolia, 31337 = anvil
    "github"        => "https://github.com/s0sta/Web3-Smart-Contract-Projects/tree/main/03-multisig-wallet",
    "liveUrl"       => "https://s0sta.com/multisig",
]);
