-- =============================================================================
-- PostgreSQL HA/DR - Database Initialization Script
-- =============================================================================
-- Creates sample schema and test data for validating the cluster.
--
-- Usage:
--   psql -h <nlb-dns> -U postgres -f sql/init-database.sql
--   OR via SSM:
--   sudo -u postgres psql -f /tmp/init-database.sql
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Schema Setup
-- -----------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS app;
SET search_path TO app, public;

-- -----------------------------------------------------------------------------
-- Tables
-- -----------------------------------------------------------------------------

-- Users table
CREATE TABLE IF NOT EXISTS app.users (
    id SERIAL PRIMARY KEY,
    username VARCHAR(50) UNIQUE NOT NULL,
    email VARCHAR(100) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    full_name VARCHAR(100),
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Products table
CREATE TABLE IF NOT EXISTS app.products (
    id SERIAL PRIMARY KEY,
    sku VARCHAR(50) UNIQUE NOT NULL,
    name VARCHAR(200) NOT NULL,
    description TEXT,
    price DECIMAL(10, 2) NOT NULL CHECK (price >= 0),
    stock_quantity INTEGER NOT NULL DEFAULT 0 CHECK (stock_quantity >= 0),
    category VARCHAR(50),
    is_available BOOLEAN DEFAULT true,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Orders table
CREATE TABLE IF NOT EXISTS app.orders (
    id SERIAL PRIMARY KEY,
    user_id INTEGER REFERENCES app.users(id) ON DELETE SET NULL,
    status VARCHAR(20) DEFAULT 'pending' CHECK (status IN ('pending', 'confirmed', 'shipped', 'delivered', 'cancelled')),
    total_amount DECIMAL(12, 2) NOT NULL DEFAULT 0,
    shipping_address TEXT,
    notes TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Order items table
CREATE TABLE IF NOT EXISTS app.order_items (
    id SERIAL PRIMARY KEY,
    order_id INTEGER REFERENCES app.orders(id) ON DELETE CASCADE,
    product_id INTEGER REFERENCES app.products(id) ON DELETE SET NULL,
    quantity INTEGER NOT NULL CHECK (quantity > 0),
    unit_price DECIMAL(10, 2) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Audit log table (for testing WAL replication)
CREATE TABLE IF NOT EXISTS app.audit_log (
    id BIGSERIAL PRIMARY KEY,
    table_name VARCHAR(50) NOT NULL,
    operation VARCHAR(10) NOT NULL,
    record_id INTEGER,
    old_data JSONB,
    new_data JSONB,
    changed_by VARCHAR(50),
    changed_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- -----------------------------------------------------------------------------
-- Indexes
-- -----------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_users_email ON app.users(email);
CREATE INDEX IF NOT EXISTS idx_users_username ON app.users(username);
CREATE INDEX IF NOT EXISTS idx_products_sku ON app.products(sku);
CREATE INDEX IF NOT EXISTS idx_products_category ON app.products(category);
CREATE INDEX IF NOT EXISTS idx_orders_user_id ON app.orders(user_id);
CREATE INDEX IF NOT EXISTS idx_orders_status ON app.orders(status);
CREATE INDEX IF NOT EXISTS idx_orders_created_at ON app.orders(created_at);
CREATE INDEX IF NOT EXISTS idx_order_items_order_id ON app.order_items(order_id);
CREATE INDEX IF NOT EXISTS idx_audit_log_table_name ON app.audit_log(table_name);
CREATE INDEX IF NOT EXISTS idx_audit_log_changed_at ON app.audit_log(changed_at);

-- -----------------------------------------------------------------------------
-- Views (useful for read replica testing)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE VIEW app.v_order_summary AS
SELECT
    o.id AS order_id,
    u.username,
    u.email,
    o.status,
    o.total_amount,
    COUNT(oi.id) AS item_count,
    o.created_at
FROM app.orders o
LEFT JOIN app.users u ON o.user_id = u.id
LEFT JOIN app.order_items oi ON o.id = oi.order_id
GROUP BY o.id, u.username, u.email, o.status, o.total_amount, o.created_at;

CREATE OR REPLACE VIEW app.v_product_inventory AS
SELECT
    category,
    COUNT(*) AS product_count,
    SUM(stock_quantity) AS total_stock,
    AVG(price)::DECIMAL(10,2) AS avg_price,
    SUM(price * stock_quantity)::DECIMAL(12,2) AS inventory_value
FROM app.products
WHERE is_available = true
GROUP BY category;

CREATE OR REPLACE VIEW app.v_daily_sales AS
SELECT
    DATE(created_at) AS sale_date,
    COUNT(*) AS order_count,
    SUM(total_amount) AS total_sales,
    AVG(total_amount)::DECIMAL(10,2) AS avg_order_value
FROM app.orders
WHERE status NOT IN ('cancelled')
GROUP BY DATE(created_at)
ORDER BY sale_date DESC;

-- -----------------------------------------------------------------------------
-- Functions and Triggers
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS tr_users_updated_at ON app.users;
CREATE TRIGGER tr_users_updated_at
    BEFORE UPDATE ON app.users
    FOR EACH ROW EXECUTE FUNCTION app.update_updated_at();

DROP TRIGGER IF EXISTS tr_products_updated_at ON app.products;
CREATE TRIGGER tr_products_updated_at
    BEFORE UPDATE ON app.products
    FOR EACH ROW EXECUTE FUNCTION app.update_updated_at();

DROP TRIGGER IF EXISTS tr_orders_updated_at ON app.orders;
CREATE TRIGGER tr_orders_updated_at
    BEFORE UPDATE ON app.orders
    FOR EACH ROW EXECUTE FUNCTION app.update_updated_at();

-- -----------------------------------------------------------------------------
-- Test Data: Users
-- -----------------------------------------------------------------------------

INSERT INTO app.users (username, email, password_hash, full_name) VALUES
    ('admin', 'admin@example.com', '$2b$12$hash1234567890abcdefghijklmnop', 'System Administrator'),
    ('johndoe', 'john.doe@example.com', '$2b$12$hash1234567890abcdefghijklmnop', 'John Doe'),
    ('janedoe', 'jane.doe@example.com', '$2b$12$hash1234567890abcdefghijklmnop', 'Jane Doe'),
    ('testuser', 'test@example.com', '$2b$12$hash1234567890abcdefghijklmnop', 'Test User'),
    ('alice', 'alice@example.com', '$2b$12$hash1234567890abcdefghijklmnop', 'Alice Smith')
ON CONFLICT (username) DO NOTHING;

-- -----------------------------------------------------------------------------
-- Test Data: Products
-- -----------------------------------------------------------------------------

INSERT INTO app.products (sku, name, description, price, stock_quantity, category) VALUES
    ('LAPTOP-001', 'Business Laptop Pro', '15.6 FHD, Intel i7, 16GB RAM, 512GB SSD', 1299.99, 50, 'Electronics'),
    ('LAPTOP-002', 'Gaming Laptop X', '17.3 4K, RTX 4080, 32GB RAM, 1TB SSD', 2499.99, 25, 'Electronics'),
    ('PHONE-001', 'Smartphone Ultra', '6.7 AMOLED, 256GB, 5G', 999.99, 100, 'Electronics'),
    ('PHONE-002', 'Smartphone Lite', '6.1 LCD, 128GB, 4G', 499.99, 150, 'Electronics'),
    ('TABLET-001', 'Pro Tablet 12', '12.9 Retina, 256GB, WiFi+5G', 1099.99, 75, 'Electronics'),
    ('HEADPHONE-001', 'Wireless Pro Headphones', 'ANC, 30hr battery, Hi-Res Audio', 349.99, 200, 'Accessories'),
    ('HEADPHONE-002', 'Sport Earbuds', 'IPX7, 24hr battery, Bluetooth 5.3', 149.99, 300, 'Accessories'),
    ('CHARGER-001', 'Fast Charger 65W', 'USB-C PD, GaN Technology', 49.99, 500, 'Accessories'),
    ('CASE-001', 'Premium Laptop Bag', '15.6 compatible, water-resistant', 79.99, 150, 'Accessories'),
    ('MOUSE-001', 'Ergonomic Wireless Mouse', '4000 DPI, Silent clicks, USB-C', 59.99, 250, 'Accessories'),
    ('KEYBOARD-001', 'Mechanical Keyboard RGB', 'Cherry MX Brown, hot-swap', 129.99, 100, 'Accessories'),
    ('MONITOR-001', '4K Monitor 27 inch', 'IPS, 144Hz, USB-C hub', 599.99, 40, 'Electronics'),
    ('DESK-001', 'Standing Desk Electric', '60x30, memory presets', 449.99, 30, 'Furniture'),
    ('CHAIR-001', 'Ergonomic Office Chair', 'Mesh back, lumbar support', 399.99, 45, 'Furniture'),
    ('WEBCAM-001', '4K Webcam Pro', 'Auto-focus, noise-canceling mic', 149.99, 120, 'Accessories')
ON CONFLICT (sku) DO NOTHING;

-- -----------------------------------------------------------------------------
-- Test Data: Orders
-- -----------------------------------------------------------------------------

INSERT INTO app.orders (user_id, status, total_amount, shipping_address, notes) VALUES
    (2, 'delivered', 1349.98, '123 Main St, New York, NY 10001', 'Leave at door'),
    (2, 'shipped', 2549.98, '123 Main St, New York, NY 10001', NULL),
    (3, 'confirmed', 999.99, '456 Oak Ave, Los Angeles, CA 90001', 'Gift wrap please'),
    (3, 'pending', 629.97, '456 Oak Ave, Los Angeles, CA 90001', NULL),
    (4, 'delivered', 449.99, '789 Pine Rd, Chicago, IL 60601', NULL),
    (5, 'cancelled', 1299.99, '321 Elm St, Houston, TX 77001', 'Customer requested cancellation'),
    (5, 'shipped', 279.98, '321 Elm St, Houston, TX 77001', NULL),
    (2, 'pending', 1699.98, '123 Main St, New York, NY 10001', 'Urgent delivery')
ON CONFLICT DO NOTHING;

-- -----------------------------------------------------------------------------
-- Test Data: Order Items
-- -----------------------------------------------------------------------------

INSERT INTO app.order_items (order_id, product_id, quantity, unit_price) VALUES
    (1, 1, 1, 1299.99),
    (1, 8, 1, 49.99),
    (2, 2, 1, 2499.99),
    (2, 8, 1, 49.99),
    (3, 3, 1, 999.99),
    (4, 6, 1, 349.99),
    (4, 7, 1, 149.99),
    (4, 11, 1, 129.99),
    (5, 13, 1, 449.99),
    (6, 1, 1, 1299.99),
    (7, 7, 1, 149.99),
    (7, 11, 1, 129.99),
    (8, 1, 1, 1299.99),
    (8, 14, 1, 399.99)
ON CONFLICT DO NOTHING;

-- -----------------------------------------------------------------------------
-- Test Data: Audit Log
-- -----------------------------------------------------------------------------

INSERT INTO app.audit_log (table_name, operation, record_id, new_data, changed_by) VALUES
    ('users', 'INSERT', 1, '{"username": "admin"}', 'system'),
    ('products', 'INSERT', 1, '{"sku": "LAPTOP-001"}', 'system'),
    ('orders', 'UPDATE', 1, '{"status": "delivered"}', 'system'),
    ('orders', 'UPDATE', 6, '{"status": "cancelled"}', 'customer_service')
ON CONFLICT DO NOTHING;

-- -----------------------------------------------------------------------------
-- Verification
-- -----------------------------------------------------------------------------

SELECT 'Users' AS table_name, COUNT(*) AS count FROM app.users
UNION ALL SELECT 'Products', COUNT(*) FROM app.products
UNION ALL SELECT 'Orders', COUNT(*) FROM app.orders
UNION ALL SELECT 'Order Items', COUNT(*) FROM app.order_items
UNION ALL SELECT 'Audit Log', COUNT(*) FROM app.audit_log;
