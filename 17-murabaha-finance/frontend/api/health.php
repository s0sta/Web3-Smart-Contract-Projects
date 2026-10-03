<?php
/**
 * Murabaha dApp — health check endpoint.
 *   https://s0sta.com/murabaha/api/health.php
 */

header("Content-Type: application/json; charset=utf-8");
header("Access-Control-Allow-Origin: *");
header("Cache-Control: no-store");

echo json_encode([
    "status" => "ok",
    "service" => "Murabaha dApp",
    "time" => date(DATE_ISO8601),
    "php" => PHP_VERSION,
]);
