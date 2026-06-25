<?php
// ============================================================
// RETAILPRO — Database Config & Shared Helpers
// ============================================================
// Edit DB_USER / DB_PASS if your XAMPP MySQL has a password.
// Default XAMPP install: root / (empty password)
// ============================================================

ini_set('display_errors', 0);          // Never leak PHP errors into JSON
error_reporting(E_ALL);

header('Content-Type: application/json; charset=utf-8');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS');
header('Access-Control-Allow-Headers: Content-Type');

// Handle CORS pre-flight
if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    http_response_code(200);
    exit;
}

// ── Credentials ──────────────────────────────────────────────
define('DB_HOST', 'localhost');
define('DB_PORT', '3306');
define('DB_NAME', 'retailpro');
define('DB_USER', 'root');
define('DB_PASS', '');          // Change if your MySQL has a password
// ─────────────────────────────────────────────────────────────

try {
    $pdo = new PDO(
        'mysql:host=' . DB_HOST . ';port=' . DB_PORT
            . ';dbname=' . DB_NAME . ';charset=utf8mb4',
        DB_USER,
        DB_PASS,
        [
            PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_EMULATE_PREPARES   => false,
        ]
    );
} catch (PDOException $e) {
    http_response_code(500);
    echo json_encode([
        'success' => false,
        'error'   => 'Database connection failed. '
                   . 'Check DB_HOST/DB_USER/DB_PASS in api/config.php. '
                   . '(' . $e->getMessage() . ')',
    ]);
    exit;
}

// ── Response helpers ─────────────────────────────────────────

function ok(array $data = []): void {
    echo json_encode(array_merge(['success' => true], $data));
    exit;
}

function fail(string $msg, int $code = 400): void {
    http_response_code($code);
    echo json_encode(['success' => false, 'error' => $msg]);
    exit;
}

// Read and decode the JSON request body
function body(): array {
    $raw = file_get_contents('php://input');
    return $raw ? (json_decode($raw, true) ?? []) : [];
}

function method(): string {
    return $_SERVER['REQUEST_METHOD'];
}
