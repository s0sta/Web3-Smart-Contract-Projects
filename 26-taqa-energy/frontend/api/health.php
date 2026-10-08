<?php
/**
 * Taqa dApp — health check endpoint.
 *   https://s0sta.com/taqa/api/health.php
 */

header("Content-Type: application/json; charset=utf-8");
header("Access-Control-Allow-Origin: *");
header("Cache-Control: no-store");

echo json_encode([
    "status" => "ok",
    "service" => "Taqa dApp",
    "time" => date(DATE_ISO8601),
    "php" => PHP_VERSION,
]);
