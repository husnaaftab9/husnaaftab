<?php
// ============================================================
// RETAILPRO — Products Endpoint
//
// GET    /api/products.php
//   → { success, products: [...] }
//
// POST   /api/products.php
//   body { name, sku, category, description, sellPrice, costPrice, quantity, minStock }
//   → { success, id }
//
// PUT    /api/products.php?id=N
//   body { name?, sku?, category?, description?, sellPrice?,
//          costPrice?, quantity?, minStock? }
//   → { success }
//
// DELETE /api/products.php?id=N
//   → { success }
// ============================================================

require __DIR__ . '/config.php';

$id = isset($_GET['id']) ? (int)$_GET['id'] : null;

// ── Map a DB row to the shape the frontend expects ───────────
function mapProduct(array $row): array {
    return [
        'id'          => (int)$row['id'],
        'name'        => $row['name'],
        'sku'         => $row['sku'],
        'category'    => $row['category'],
        'description' => $row['description'] ?? '',
        'sellPrice'   => (float)$row['sell_price'],
        'costPrice'   => (float)$row['cost_price'],
        'quantity'    => (int)$row['quantity'],
        'minStock'    => (int)$row['min_stock'],
    ];
}

// ── Resolve (or create) a category ID by name ────────────────
function categoryId(PDO $pdo, string $name): int {
    $stmt = $pdo->prepare('SELECT id FROM categories WHERE name = ? LIMIT 1');
    $stmt->execute([trim($name)]);
    $row = $stmt->fetch();
    if ($row) return (int)$row['id'];

    // Auto-insert unknown categories so new products never fail
    $ins = $pdo->prepare('INSERT INTO categories (name) VALUES (?)');
    $ins->execute([trim($name)]);
    return (int)$pdo->lastInsertId();
}

switch (method()) {

    // ── GET: return all active products ──────────────────────
    case 'GET':
        $stmt = $pdo->query('
            SELECT p.id, p.name, p.sku,
                   c.name  AS category,
                   p.description,
                   p.sell_price, p.cost_price,
                   p.quantity,  p.min_stock
            FROM   products   p
            JOIN   categories c ON c.id = p.category_id
            WHERE  p.is_active = 1
            ORDER  BY p.name
        ');
        ok(['products' => array_map('mapProduct', $stmt->fetchAll())]);
        break;

    // ── POST: create a new product ───────────────────────────
    case 'POST':
        $b    = body();
        $name = trim($b['name'] ?? '');
        $sku  = trim($b['sku']  ?? '');

        if (!$name) fail('Product name is required.');
        if (!$sku)  fail('SKU is required.');

        // Prevent duplicate SKUs
        $chk = $pdo->prepare(
            'SELECT id FROM products WHERE sku = ? AND is_active = 1 LIMIT 1'
        );
        $chk->execute([$sku]);
        if ($chk->fetch()) fail("SKU \"$sku\" already exists.");

        $catId = categoryId($pdo, $b['category'] ?? 'Other');

        $stmt = $pdo->prepare('
            INSERT INTO products
                (name, sku, category_id, description,
                 sell_price, cost_price, quantity, min_stock)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ');
        $stmt->execute([
            $name, $sku, $catId,
            trim($b['description'] ?? ''),
            (float)($b['sellPrice'] ?? 0),
            (float)($b['costPrice'] ?? 0),
            max(0, (int)($b['quantity'] ?? 0)),
            max(0, (int)($b['minStock'] ?? 0)),
        ]);

        ok(['id' => (int)$pdo->lastInsertId()]);
        break;

    // ── PUT: update one or more fields of a product ──────────
    case 'PUT':
        if (!$id) fail('Product ID is required in the URL (?id=N).');

        $b      = body();
        $fields = [];
        $params = [];

        if (array_key_exists('name', $b)) {
            if (!trim($b['name'])) fail('Product name cannot be empty.');
            $fields[] = 'name = ?';        $params[] = trim($b['name']);
        }
        if (array_key_exists('sku', $b)) {
            if (!trim($b['sku'])) fail('SKU cannot be empty.');
            // Ensure no other active product uses this SKU
            $chk = $pdo->prepare(
                'SELECT id FROM products WHERE sku = ? AND id != ? AND is_active = 1 LIMIT 1'
            );
            $chk->execute([trim($b['sku']), $id]);
            if ($chk->fetch()) fail("SKU \"{$b['sku']}\" is already used by another product.");
            $fields[] = 'sku = ?';         $params[] = trim($b['sku']);
        }
        if (array_key_exists('category', $b)) {
            $fields[] = 'category_id = ?'; $params[] = categoryId($pdo, $b['category']);
        }
        if (array_key_exists('description', $b)) {
            $fields[] = 'description = ?'; $params[] = trim($b['description']);
        }
        if (array_key_exists('sellPrice', $b)) {
            $fields[] = 'sell_price = ?';  $params[] = max(0, (float)$b['sellPrice']);
        }
        if (array_key_exists('costPrice', $b)) {
            $fields[] = 'cost_price = ?';  $params[] = max(0, (float)$b['costPrice']);
        }
        if (array_key_exists('quantity', $b)) {
            $fields[] = 'quantity = ?';    $params[] = max(0, (int)$b['quantity']);
        }
        if (array_key_exists('minStock', $b)) {
            $fields[] = 'min_stock = ?';   $params[] = max(0, (int)$b['minStock']);
        }

        if (!$fields) fail('No fields provided to update.');

        $params[] = $id;
        $pdo->prepare(
            'UPDATE products SET ' . implode(', ', $fields)
            . ' WHERE id = ? AND is_active = 1'
        )->execute($params);

        ok();
        break;

    // ── DELETE: soft-delete (set is_active = 0) ──────────────
    case 'DELETE':
        if (!$id) fail('Product ID is required in the URL (?id=N).');

        $pdo->prepare('UPDATE products SET is_active = 0 WHERE id = ?')
            ->execute([$id]);

        ok();
        break;

    default:
        fail('Method not allowed.', 405);
}
