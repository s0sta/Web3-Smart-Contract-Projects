<?php
/**
 * Estate Tokenization dApp — server-side config (optional)
 * The frontend works fully without PHP; on Hostinger this file can
 * override js/config.js at load time (only when the visitor has not
 * saved their own address in localStorage).
 */

header("Content-Type: application/json; charset=utf-8");
header("Access-Control-Allow-Origin: *");
header("Cache-Control: no-store");

echo json_encode([
    "site"             => "Estate Tokenization dApp",
    // Deployed on Sepolia testnet (owner: 0x319899FaAAD730519B8a2Bd72d2Eba2370a9B853).
    "registryAddress"  => "0x12dd8571779A707E931471c38D631D8542046180",
    "distributorAddress" => "0xc712C6ADb5c00D91AC42606E1956f910934B6D9a",
    "stableAddress"    => "0x05cD5A021f0fEd5Cf3AC44845E31a81b5E3D42Ee",
    "defaultChainId"   => 11155111,
    "github"           => "https://github.com/s0sta/Web3-Smart-Contract-Projects/tree/main/12-realestate-tokenization",
    "liveUrl"          => "https://s0sta.com/estate",
]);
