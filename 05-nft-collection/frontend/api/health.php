<?php
/**
 * Genesis Collection dApp — health check endpoint.
 *   https://nft.s0sta.com/api/health.php
 */

header("Content-Type: application/json; charset=utf-8");
header("Access-Control-Allow-Origin: *");
header("Cache-Control: no-store");

echo json_encode([
    "status" => "ok",
    "service" => "Genesis Collection dApp",
    "time" => date(DATE_ISO8601),
    "php" => PHP_VERSION,
]);
