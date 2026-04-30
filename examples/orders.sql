-- examples/orders.sql
--
-- In-memory order-fulfillment demo for ScryQL. Self-contained: no
-- external services, no Parquet files; all data lives in DuckDB's
-- in-memory engine, seeded from the @setup block.
--
-- See examples/orders.md for the walkthrough.

-- @setup
CREATE TABLE orders (
    id          VARCHAR PRIMARY KEY,
    customer_id VARCHAR,
    total       DECIMAL(10,2),
    placed_at   DATE
);
CREATE TABLE order_lines (
    order_id   VARCHAR,
    product_id VARCHAR,
    qty        INTEGER
);
CREATE TABLE customers (
    id      VARCHAR PRIMARY KEY,
    name    VARCHAR,
    country VARCHAR,
    active  BOOLEAN
);
CREATE TABLE inventory (
    product_id VARCHAR PRIMARY KEY,
    on_hand    INTEGER
);
CREATE TABLE payments (
    order_id        VARCHAR,
    captured_amount DECIMAL(10,2),
    status          VARCHAR
);
CREATE TABLE shipments (
    order_id    VARCHAR,
    tracking_no VARCHAR,
    status      VARCHAR
);

INSERT INTO orders VALUES
    ('ORD-1001', 'CUST-A',  89.50, '2026-04-20'),
    ('ORD-1002', 'CUST-B', 120.00, '2026-04-21'),
    ('ORD-1003', 'CUST-A',  45.00, '2026-04-22'),
    ('ORD-1004', 'CUST-C', 200.00, '2026-04-23'),
    ('ORD-1005', 'CUST-A',  60.00, '2026-04-24');

INSERT INTO order_lines VALUES
    ('ORD-1001', 'WIDGET',   1),
    ('ORD-1001', 'GIZMO',    2),
    ('ORD-1002', 'GIZMO',    1),
    ('ORD-1003', 'WIDGET',   1),
    ('ORD-1004', 'SPROCKET', 5),
    ('ORD-1005', 'WIDGET',   1);

INSERT INTO customers VALUES
    ('CUST-A', 'Anna Andrews', 'GB', true),
    ('CUST-B', 'Bert Brown',   'GB', false),
    ('CUST-C', 'Cara Clarke',  'GB', true);

INSERT INTO inventory VALUES
    ('WIDGET',   100),
    ('GIZMO',     50),
    ('SPROCKET',   0);

INSERT INTO payments VALUES
    ('ORD-1001',  89.50, 'captured'),
    ('ORD-1002', 120.00, 'captured'),
    ('ORD-1003',  30.00, 'captured'),
    ('ORD-1004', 200.00, 'captured'),
    ('ORD-1005',  60.00, 'captured');

INSERT INTO shipments VALUES
    ('ORD-1001', 'TRK-AAA', 'shipped'),
    ('ORD-1002', 'TRK-BBB', 'shipped'),
    ('ORD-1003', 'TRK-CCC', 'pending');

-- @row : the order header
SELECT 'order(''' || id || ''', ''' || customer_id || ''', '
       || total || ', ''' || placed_at || ''').'
FROM orders WHERE id = ?;

-- @row : the customer joined through orders.customer_id
SELECT 'customer(''' || c.id || ''', ''' || replace(c.name, '''', '''''') || ''', '
       || (CASE WHEN c.active THEN 'active' ELSE 'inactive' END) || ').'
FROM customers c
JOIN orders o ON o.customer_id = c.id
WHERE o.id = ?;

-- @row : one line predicate per order line, joined with current stock
SELECT 'line(''' || ol.product_id || ''', ' || ol.qty || ', '
       || COALESCE(i.on_hand, 0) || ').'
FROM order_lines ol
LEFT JOIN inventory i USING (product_id)
WHERE ol.order_id = ?;

-- @row : the payment for this order
SELECT 'payment(' || captured_amount || ', ''' || status || ''').'
FROM payments WHERE order_id = ?;

-- @row : the shipment (if any)
SELECT 'shipment(''' || tracking_no || ''', ''' || status || ''').'
FROM shipments WHERE order_id = ?;
