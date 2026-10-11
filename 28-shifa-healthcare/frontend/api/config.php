<?php
/**
 * Shifa dApp — server-side config (optional).
 * On the host this can pre-fill the registry address for first-time visitors.
 */

header("Content-Type: application/json; charset=utf-8");
header("Access-Control-Allow-Origin: *");
header("Cache-Control: no-store");

echo json_encode([
    "site"            => "Shifa dApp",
    // Deployed on Sepolia testnet.
    "registryAddress" => "0xB4A139e894c752765d0c2FD69CBE538f1013cA20",
    "defaultChainId"  => 11155111,
    "github"          => "https://github.com/s0sta/Web3-Smart-Contract-Projects/tree/main/28-shifa-healthcare",
    "liveUrl"         => "https://s0sta.com/Web3-Smart-Contract-Projects/shifa",
]);
