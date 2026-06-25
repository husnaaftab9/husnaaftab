<?php
// ============================================================
// RETAILPRO — Sales Endpoint
//
// GET  /api/sales.php
//   → { success, sales: [...] }
//
// POST /api/sales.php
//   body { productId, quantity, date, userId? }
//   → { success, sale: {...}, newProductQty }
//   Atomically deducts stock and records the sale in a
//   transaction, matching the logic in the record_sale proc.
// ============================================================

require __DIR__ . '/config.php';

// ── Map a DB row to the shape the frontend expects ───────────
function mapSale(array $row): array {
    return [
        'id'          => (int)$row['id'],
        'date'        => $row['sale_date'],
        'productId'   => (int)$row['product_id'],
        'productName' => $row['product_name'],
        'quantity'    => (int)$row['quantity'],
        'unitPrice'   => (float)$row['unit_price'],
        'total'       => (float)$row['total'],
        'stockAfter'  => (int)$row['stock_after'],
    ];
}

switch (method()) {

    // ── GET: all sales, newest first ─────────────────────────
    case 'GET':
        $stmt = $pdo->query('
            SELECT id, product_id, product_name,
                   quantity, unit_price, total,
                   stock_after, sale_date
            FROM   sales
            ORDER  BY sale_date DESC, id DESC
        ');
        ok(['sales' => array_map('mapSale', $stmt->fetchAll())]);
        break;

    // ── POST: record a sale + deduct stock atomically ────────
    case 'POST':
        $b         = body();
        $productId = (int)($b['productId'] ?? 0);
        $qty       = (int)($b['quantity']  ?? 0);
        $saleDate  = $b['date']   ?? date('Y-m-d');
        $userId    = isset($b['userId']) ? (int)$b['userId'] : null;

        if (!$productId) fail('productId is required.');
        if ($qty < 1)    fail('Quantity must be at least 1.');

        // Validate date format
        if (!preg_match('/^\d{4}-\d{2}-\d{2}$/', $saleDate)) {
            $saleDate = date('Y-m-d');
        }

        $pdo->beginTransaction();
        try {
            // Lock the product row to prevent race conditions
            $stmt = $pdo->prepare('
                SELECT name, sell_price, quantity
                FROM   products
                WHERE  id = ? AND is_active = 1
                FOR UPDATE
            ');
            $stmt->execute([$productId]);
            $product = $stmt->fetch();

            if (!$product) {
                $pdo->rollBack();
                fail('Product not found or inactive.');
            }
            if ($qty > $product['quantity']) {
                $pdo->rollBack();
                fail('Only ' . $product['quantity'] . ' unit(s) available in stock.');
            }

            $stockAfter = $product['quantity'] - $qty;
            $unitPrice  = (float)$product['sell_price'];

            // Deduct stock
            $pdo->prepare('UPDATE products SET quantity = ? WHERE id = ?')
                ->execute([$stockAfter, $productId]);

            // Record sale (total is a generated column — omit from INSERT)
            $ins = $pdo->prepare('
                INSERT INTO sales
                    (product_id, product_name, quantity,
                     unit_price, stock_after, sale_date, created_by)
                VALUES (?, ?, ?, ?, ?, ?, ?)
            ');
            $ins->execute([
                $productId, $product['name'], $qty,
                $unitPrice, $stockAfter, $saleDate, $userId,
            ]);
            $saleId = (int)$pdo->lastInsertId();

            // Write audit trail
            $pdo->prepare('
                INSERT INTO stock_adjustments
                    (product_id, adjusted_by, change_qty,
                     qty_before, qty_after, reason)
                VALUES (?, ?, ?, ?, ?, ?)
            ')->execute([
                $productId, $userId, -$qty,
                $product['quantity'], $stockAfter,
                "Sale #$saleId",
            ]);

            $pdo->commit();

            ok([
                'sale' => [
                    'id'          => $saleId,
                    'date'        => $saleDate,
                    'productId'   => $productId,
                    'productName' => $product['name'],
                    'quantity'    => $qty,
                    'unitPrice'   => $unitPrice,
                    'total'       => $qty * $unitPrice,
                    'stockAfter'  => $stockAfter,
                ],
                'newProductQty' => $stockAfter,
            ]);

        } catch (PDOException $e) {
            if ($pdo->inTransaction()) $pdo->rollBack();
            fail('Sale transaction failed: ' . $e->getMessage(), 500);
        }
        break;

    default:
        fail('Method not allowed.', 405);
}
