<?php
/**
 * Shifa dApp — health check endpoint.
 */

header("Content-Type: application/json; charset=utf-8");
header("Access-Control-Allow-Origin: *");
header("Cache-Control: no-store");

echo json_encode([
    "status"  => "ok",
    "service" => "Shifa dApp",
    "time"    => date(DATE_ISO8601),
    "php"     => PHP_VERSION,
]);
