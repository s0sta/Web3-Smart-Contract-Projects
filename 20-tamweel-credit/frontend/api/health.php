<?php
/**
 * Tamweel dApp — health check endpoint.
 *   https://s0sta.com/tamweel/api/health.php
 */

header("Content-Type: application/json; charset=utf-8");
header("Access-Control-Allow-Origin: *");
header("Cache-Control: no-store");

echo json_encode([
    "status" => "ok",
    "service" => "Tamweel dApp",
    "time" => date(DATE_ISO8601),
    "php" => PHP_VERSION,
]);
