<?php
/**
 * NovaToken dApp — health check endpoint.
 * Useful to verify the subdomain and PHP are serving correctly:
 *   https://erc-20Token.s0sta.com/api/health.php
 */

header("Content-Type: application/json; charset=utf-8");
header("Access-Control-Allow-Origin: *");
header("Cache-Control: no-store");

echo json_encode([
    "status" => "ok",
    "service" => "NovaToken dApp",
    "time" => date(DATE_ISO8601),
    "php" => PHP_VERSION,
]);
