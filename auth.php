<?php
// ============================================================
// RETAILPRO — Auth Endpoint
// POST  /api/auth.php   { email, password }
//   → { success, user: { id, name, email, role } }
//   → { success: false, error }
// ============================================================

require __DIR__ . '/config.php';

if (method() !== 'POST') fail('Method not allowed.', 405);

$b        = body();
$email    = trim($b['email']    ?? '');
$password = trim($b['password'] ?? '');

if (!$email || !$password) fail('Email and password are required.');

$stmt = $pdo->prepare(
    'SELECT id, name, email, role
     FROM   users
     WHERE  email = ? AND password = ? AND is_active = 1
     LIMIT  1'
);
$stmt->execute([$email, $password]);
$user = $stmt->fetch();

if (!$user) {
    fail('Invalid email or password.', 401);
}

ok(['user' => $user]);
