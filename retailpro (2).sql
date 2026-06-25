-- ============================================================
-- INVENTORY RETAIL PRO — Complete Database Schema & Seed Data
-- Compatible with: MySQL 8+, MariaDB 10.3+
-- Usage:  mysql -u root -p < retailpro.sql
--         OR paste into phpMyAdmin / MySQL Workbench
-- ============================================================

-- Create & select the database
CREATE DATABASE IF NOT EXISTS retailpro
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

USE retailpro;

-- ============================================================
-- TABLE: users
-- ============================================================
CREATE TABLE IF NOT EXISTS users (
  id         INT          UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  name       VARCHAR(100) NOT NULL,
  email      VARCHAR(150) NOT NULL UNIQUE,
  password   VARCHAR(255) NOT NULL COMMENT 'bcrypt hash in production; plain text for demo',
  role       ENUM('admin','manager','staff') NOT NULL DEFAULT 'staff',
  is_active  TINYINT(1)   NOT NULL DEFAULT 1,
  created_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB;

-- ============================================================
-- TABLE: categories
-- ============================================================
CREATE TABLE IF NOT EXISTS categories (
  id         INT          UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  name       VARCHAR(100) NOT NULL UNIQUE,
  created_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

-- ============================================================
-- TABLE: products
-- ============================================================
CREATE TABLE IF NOT EXISTS products (
  id          INT           UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  name        VARCHAR(200)  NOT NULL,
  sku         VARCHAR(50)   NOT NULL UNIQUE,
  category_id INT           UNSIGNED NOT NULL,
  description TEXT,
  sell_price  DECIMAL(10,2) NOT NULL DEFAULT 0.00,
  cost_price  DECIMAL(10,2) NOT NULL DEFAULT 0.00,
  quantity    INT           NOT NULL DEFAULT 0,
  min_stock   INT           NOT NULL DEFAULT 5 COMMENT 'Low-stock alert threshold',
  is_active   TINYINT(1)    NOT NULL DEFAULT 1,
  created_at  DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at  DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  CONSTRAINT fk_product_category FOREIGN KEY (category_id)
    REFERENCES categories(id) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB;

-- ============================================================
-- TABLE: sales
-- ============================================================
CREATE TABLE IF NOT EXISTS sales (
  id           INT           UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  product_id   INT           UNSIGNED NOT NULL,
  product_name VARCHAR(200)  NOT NULL COMMENT 'Snapshot — kept even if product is deleted',
  quantity     INT           NOT NULL CHECK (quantity > 0),
  unit_price   DECIMAL(10,2) NOT NULL,
  total        DECIMAL(10,2) GENERATED ALWAYS AS (quantity * unit_price) STORED,
  stock_after  INT           NOT NULL COMMENT 'Stock level immediately after this sale',
  sale_date    DATE          NOT NULL DEFAULT (CURRENT_DATE),
  notes        TEXT,
  created_by   INT           UNSIGNED,
  created_at   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_sale_product FOREIGN KEY (product_id)
    REFERENCES products(id) ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT fk_sale_user FOREIGN KEY (created_by)
    REFERENCES users(id) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB;

-- ============================================================
-- TABLE: stock_adjustments  (audit trail for inventory changes)
-- ============================================================
CREATE TABLE IF NOT EXISTS stock_adjustments (
  id            INT          UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  product_id    INT          UNSIGNED NOT NULL,
  adjusted_by   INT          UNSIGNED,
  change_qty    INT          NOT NULL COMMENT 'Positive = added, Negative = removed',
  qty_before    INT          NOT NULL,
  qty_after     INT          NOT NULL,
  reason        VARCHAR(255),
  adjusted_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT fk_adj_product FOREIGN KEY (product_id)
    REFERENCES products(id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_adj_user FOREIGN KEY (adjusted_by)
    REFERENCES users(id) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB;

-- ============================================================
-- INDEXES  (speed up common queries)
-- ============================================================
CREATE INDEX idx_products_sku         ON products (sku);
CREATE INDEX idx_products_category    ON products (category_id);
CREATE INDEX idx_products_quantity    ON products (quantity);
CREATE INDEX idx_sales_product        ON sales (product_id);
CREATE INDEX idx_sales_date           ON sales (sale_date);
CREATE INDEX idx_adj_product          ON stock_adjustments (product_id);
CREATE INDEX idx_adj_date             ON stock_adjustments (adjusted_at);

-- ============================================================
-- USEFUL VIEWS
-- ============================================================

-- v_low_stock: products at or below their minimum threshold
CREATE OR REPLACE VIEW v_low_stock AS
  SELECT
    p.id,
    p.name,
    p.sku,
    c.name             AS category,
    p.quantity,
    p.quantity         AS current_qty,
    p.min_stock,
    (p.min_stock - p.quantity) AS units_needed,
    CASE
      WHEN p.quantity = 0            THEN 'Out of Stock'
      WHEN p.quantity <= p.min_stock THEN 'Low Stock'
    END AS stock_status
  FROM products p
  JOIN categories c ON c.id = p.category_id
  WHERE p.quantity <= p.min_stock
    AND p.is_active = 1
  ORDER BY p.quantity ASC;

-- v_inventory_value: stock value per product
CREATE OR REPLACE VIEW v_inventory_value AS
  SELECT
    p.id,
    p.name,
    p.sku,
    c.name                              AS category,
    p.quantity,
    p.cost_price,
    p.sell_price,
    (p.quantity * p.cost_price)         AS stock_value_cost,
    (p.quantity * p.sell_price)         AS stock_value_retail,
    (p.sell_price - p.cost_price)       AS margin_per_unit,
    ROUND(
      (p.sell_price - p.cost_price)
      / NULLIF(p.sell_price, 0) * 100, 2
    )                                   AS margin_pct
  FROM products p
  JOIN categories c ON c.id = p.category_id
  WHERE p.is_active = 1;

-- v_sales_summary: daily revenue totals
CREATE OR REPLACE VIEW v_sales_summary AS
  SELECT
    sale_date,
    COUNT(*)        AS num_transactions,
    SUM(quantity)   AS units_sold,
    SUM(total)      AS revenue
  FROM sales
  GROUP BY sale_date
  ORDER BY sale_date DESC;

-- v_top_products: products ranked by units sold
CREATE OR REPLACE VIEW v_top_products AS
  SELECT
    s.product_id,
    s.product_name,
    SUM(s.quantity)  AS total_units_sold,
    SUM(s.total)     AS total_revenue,
    COUNT(s.id)      AS num_sales
  FROM sales s
  GROUP BY s.product_id, s.product_name
  ORDER BY total_units_sold DESC;

-- ============================================================
-- STORED PROCEDURE: record_sale
-- Safely records a sale and deducts stock in one transaction
-- Usage: CALL record_sale(5, 3, CURDATE(), 1, @result_msg);
-- ============================================================
DELIMITER $$

CREATE PROCEDURE record_sale (
  IN  p_product_id  INT,
  IN  p_quantity    INT,
  IN  p_sale_date   DATE,
  IN  p_user_id     INT,
  OUT p_message     VARCHAR(255)
)
BEGIN
  DECLARE v_qty_available INT DEFAULT 0;
  DECLARE v_sell_price    DECIMAL(10,2) DEFAULT 0;
  DECLARE v_product_name  VARCHAR(200) DEFAULT '';
  DECLARE v_stock_after   INT DEFAULT 0;

  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    SET p_message = 'ERROR: Transaction failed and was rolled back.';
  END;

  START TRANSACTION;

  -- Lock the product row to prevent race conditions
  SELECT name, sell_price, quantity
  INTO   v_product_name, v_sell_price, v_qty_available
  FROM   products
  WHERE  id = p_product_id AND is_active = 1
  FOR UPDATE;

  IF v_product_name IS NULL THEN
    ROLLBACK;
    SET p_message = 'ERROR: Product not found or inactive.';
  ELSEIF p_quantity < 1 THEN
    ROLLBACK;
    SET p_message = 'ERROR: Quantity must be at least 1.';
  ELSEIF p_quantity > v_qty_available THEN
    ROLLBACK;
    SET p_message = CONCAT('ERROR: Only ', v_qty_available, ' units available.');
  ELSE
    SET v_stock_after = v_qty_available - p_quantity;

    -- Deduct stock
    UPDATE products
    SET    quantity = v_stock_after
    WHERE  id = p_product_id;

    -- Record the sale
    INSERT INTO sales (product_id, product_name, quantity, unit_price, stock_after, sale_date, created_by)
    VALUES (p_product_id, v_product_name, p_quantity, v_sell_price, v_stock_after, p_sale_date, p_user_id);

    -- Audit trail
    INSERT INTO stock_adjustments (product_id, adjusted_by, change_qty, qty_before, qty_after, reason)
    VALUES (p_product_id, p_user_id, -p_quantity, v_qty_available, v_stock_after, CONCAT('Sale #', LAST_INSERT_ID()));

    COMMIT;
    SET p_message = CONCAT('OK: Sale recorded. Stock reduced from ', v_qty_available, ' to ', v_stock_after, '.');
  END IF;
END$$

-- ============================================================
-- STORED PROCEDURE: add_stock
-- Adds stock and writes an audit entry
-- Usage: CALL add_stock(5, 20, 'Restocked from supplier', 1, @msg);
-- ============================================================
CREATE PROCEDURE add_stock (
  IN  p_product_id  INT,
  IN  p_add_qty     INT,
  IN  p_reason      VARCHAR(255),
  IN  p_user_id     INT,
  OUT p_message     VARCHAR(255)
)
BEGIN
  DECLARE v_qty_before INT DEFAULT 0;
  DECLARE v_qty_after  INT DEFAULT 0;

  IF p_add_qty < 1 THEN
    SET p_message = 'ERROR: add_qty must be at least 1.';
  ELSE
    SELECT quantity INTO v_qty_before FROM products WHERE id = p_product_id;

    IF v_qty_before IS NULL THEN
      SET p_message = 'ERROR: Product not found.';
    ELSE
      SET v_qty_after = v_qty_before + p_add_qty;

      UPDATE products SET quantity = v_qty_after WHERE id = p_product_id;

      INSERT INTO stock_adjustments (product_id, adjusted_by, change_qty, qty_before, qty_after, reason)
      VALUES (p_product_id, p_user_id, p_add_qty, v_qty_before, v_qty_after, IFNULL(p_reason, 'Manual restock'));

      SET p_message = CONCAT('OK: Added ', p_add_qty, ' units. New stock: ', v_qty_after, '.');
    END IF;
  END IF;
END$$

DELIMITER ;

-- ============================================================
-- SEED DATA — Demo Users
-- ============================================================
INSERT INTO users (name, email, password, role) VALUES
  ('Admin User',    'admin@retailpro.com',   'admin123',   'admin'),
  ('Store Manager', 'manager@retailpro.com', 'manager123', 'manager'),
  ('Sales Staff',   'staff@retailpro.com',   'staff123',   'staff');

-- ============================================================
-- SEED DATA — Categories
-- ============================================================
INSERT INTO categories (name) VALUES
  ('Electronics'),
  ('Clothing'),
  ('Food & Beverage'),
  ('Office Supplies'),
  ('Other');

-- ============================================================
-- SEED DATA — Products
-- ============================================================
INSERT INTO products (name, sku, category_id, description, sell_price, cost_price, quantity, min_stock) VALUES
  ('MacBook Pro 14"',        'PRD-001', 1, '14-inch laptop with M3 chip, 16GB RAM, 512GB SSD',     1699.00, 1299.00, 15,  5),
  ('iPhone 15 Case',         'PRD-002', 1, 'Slim TPU protective case for iPhone 15, clear finish',   19.99,    8.00,  3, 10),
  ('Office Chair Ergonomic', 'PRD-003', 4, 'Lumbar support office chair, adjustable height & arms', 249.00,  150.00,  8,  3),
  ('Blue Polo Shirt (M)',    'PRD-004', 2, '100% cotton polo shirt, medium size, navy blue',         28.00,   12.00,  0,  5),
  ('Wireless Mouse',         'PRD-005', 1, '2.4GHz wireless optical mouse, 1600 DPI adjustable',    35.00,   18.00, 25,  8),
  ('A4 Paper Ream (500s)',   'PRD-006', 4, '80gsm A4 white copy paper, 500 sheets per ream',          9.00,    4.00,  2, 20),
  ('Energy Drink 24pk',      'PRD-007', 3, 'Assorted energy drinks, 250ml cans, 24 per case',        36.00,   22.00, 50, 10),
  ('USB-C Hub 7-Port',       'PRD-008', 1, '7-in-1 USB-C hub with HDMI 4K, 3×USB3, SD/microSD',    65.00,   35.00, 12,  5),
  ('Ballpoint Pens (Box)',   'PRD-009', 4, 'Blue ballpoint pens, box of 50, smooth write',            8.50,    3.50, 30, 10),
  ('Running Shoes (Size 9)', 'PRD-010', 2, 'Lightweight mesh running shoes, unisex, size 9',         89.99,   45.00,  6,  4);

-- ============================================================
-- SEED DATA — Sales (last 7 days)
-- ============================================================
INSERT INTO sales (product_id, product_name, quantity, unit_price, stock_after, sale_date, created_by) VALUES
  (1, 'MacBook Pro 14"',        2, 1699.00, 13, CURDATE(),            1),
  (5, 'Wireless Mouse',         3,   35.00, 22, DATE_SUB(CURDATE(),INTERVAL 1 DAY), 1),
  (8, 'USB-C Hub 7-Port',       1,   65.00, 11, DATE_SUB(CURDATE(),INTERVAL 2 DAY), 2),
  (7, 'Energy Drink 24pk',      5,   36.00, 45, DATE_SUB(CURDATE(),INTERVAL 3 DAY), 2),
  (3, 'Office Chair Ergonomic', 1,  249.00,  7, DATE_SUB(CURDATE(),INTERVAL 4 DAY), 1),
  (9, 'Ballpoint Pens (Box)',   4,    8.50, 26, DATE_SUB(CURDATE(),INTERVAL 5 DAY), 3),
  (5, 'Wireless Mouse',         2,   35.00, 20, DATE_SUB(CURDATE(),INTERVAL 6 DAY), 3),
  (10,'Running Shoes (Size 9)', 1,   89.99,  5, DATE_SUB(CURDATE(),INTERVAL 6 DAY), 2);

-- ============================================================
-- SEED DATA — Stock Adjustment Audit Trail
-- ============================================================
INSERT INTO stock_adjustments (product_id, adjusted_by, change_qty, qty_before, qty_after, reason) VALUES
  (1, 1,  20,  0,  20, 'Initial stock load'),
  (2, 1,   5,  0,   5, 'Initial stock load'),
  (3, 1,  10,  0,  10, 'Initial stock load'),
  (4, 1,  10,  0,  10, 'Initial stock load'),
  (5, 1,  30,  0,  30, 'Initial stock load'),
  (6, 1,  10,  0,  10, 'Initial stock load'),
  (7, 1,  60,  0,  60, 'Initial stock load'),
  (8, 1,  15,  0,  15, 'Initial stock load'),
  (9, 1,  40,  0,  40, 'Initial stock load'),
  (10,1,   8,  0,   8, 'Initial stock load'),
  (4, 1, -10,  10,  0, 'Damaged goods written off');

-- ============================================================
-- QUICK VERIFICATION QUERIES (comment out if not needed)
-- ============================================================
SELECT 'Users'    AS table_name, COUNT(*) AS rows_inserted FROM users
UNION ALL
SELECT 'Categories',              COUNT(*) FROM categories
UNION ALL
SELECT 'Products',                COUNT(*) FROM products
UNION ALL
SELECT 'Sales',                   COUNT(*) FROM sales
UNION ALL
SELECT 'Stock Adjustments',       COUNT(*) FROM stock_adjustments;

SELECT '--- Low Stock Items ---' AS info;
SELECT name, quantity, min_stock, stock_status FROM v_low_stock;

SELECT '--- Inventory Value ---' AS info;
SELECT name, quantity, cost_price, stock_value_cost, margin_pct FROM v_inventory_value ORDER BY stock_value_cost DESC;
