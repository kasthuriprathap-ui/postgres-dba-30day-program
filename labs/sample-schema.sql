-- =====================================================================
-- Sample schema for the PostgreSQL DBA 30-day program.
--
-- Load into your local Docker cluster on Day 2:
--     docker exec -i pgdba psql -U postgres -d postgres < sample-schema.sql
--
-- Or against a managed instance:
--     psql "$PG_URL" -f sample-schema.sql
--
-- What this builds:
--   * Database:  shop
--   * Roles:     app_owner, app_rw, app_ro, app_deploy (groups)
--                svc_app, svc_bi, svc_deploy (login roles)
--   * Schema:    sales
--   * Tables:    sales.customers, sales.orders, sales.order_items,
--                sales.events (partitioned monthly, one initial partition)
--   * Sample data (small): 500 customers, ~2000 orders
-- =====================================================================

-- Fresh start (rerunnable)
DROP DATABASE IF EXISTS shop;
CREATE DATABASE shop
  TEMPLATE = template0
  ENCODING = 'UTF8'
  LC_COLLATE = 'C'
  LC_CTYPE   = 'C';

-- Roles are cluster-scoped: create them if missing, do not fail if they exist.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_owner')  THEN CREATE ROLE app_owner  NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_rw')     THEN CREATE ROLE app_rw     NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_ro')     THEN CREATE ROLE app_ro     NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_deploy') THEN CREATE ROLE app_deploy NOLOGIN CREATEROLE; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'svc_app')    THEN CREATE ROLE svc_app    LOGIN PASSWORD 'svc_app_pw'    IN ROLE app_rw; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'svc_bi')     THEN CREATE ROLE svc_bi     LOGIN PASSWORD 'svc_bi_pw'     IN ROLE app_ro; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'svc_deploy') THEN CREATE ROLE svc_deploy LOGIN PASSWORD 'svc_deploy_pw' IN ROLE app_deploy; END IF;
END $$;

ALTER DATABASE shop OWNER TO app_owner;

\connect shop

-- Extensions: enable the two you'll want everywhere.
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Schema owned by app_owner
CREATE SCHEMA IF NOT EXISTS sales AUTHORIZATION app_owner;

-- Grants
GRANT CONNECT ON DATABASE shop TO app_rw, app_ro, app_deploy;
GRANT USAGE  ON SCHEMA sales   TO app_rw, app_ro;
GRANT USAGE, CREATE ON SCHEMA sales TO app_deploy;

-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------

SET ROLE app_deploy;

CREATE TABLE sales.customers (
  id          bigint       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  email       text         NOT NULL UNIQUE,
  full_name   text         NOT NULL,
  tier        text         NOT NULL DEFAULT 'silver' CHECK (tier IN ('bronze','silver','gold','platinum')),
  attributes  jsonb        NOT NULL DEFAULT '{}'::jsonb,
  created_at  timestamptz  NOT NULL DEFAULT now()
);

CREATE INDEX customers_email_lower_idx ON sales.customers ((lower(email)));
CREATE INDEX customers_attributes_gin  ON sales.customers USING gin (attributes jsonb_path_ops);

CREATE TABLE sales.orders (
  id           bigint       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id  bigint       NOT NULL REFERENCES sales.customers(id) ON DELETE RESTRICT,
  status       text         NOT NULL DEFAULT 'open' CHECK (status IN ('open','paid','shipped','cancelled','refunded')),
  total        numeric(12,2) NOT NULL CHECK (total >= 0),
  tags         text[]       NOT NULL DEFAULT '{}',
  ordered_at   timestamptz  NOT NULL DEFAULT now()
);

CREATE INDEX orders_customer_idx        ON sales.orders (customer_id);
CREATE INDEX orders_open_by_customer    ON sales.orders (customer_id) INCLUDE (total, ordered_at) WHERE status = 'open';
CREATE INDEX orders_tags_gin            ON sales.orders USING gin (tags);
CREATE INDEX orders_ordered_at_brin     ON sales.orders USING brin (ordered_at) WITH (pages_per_range = 32);

CREATE TABLE sales.order_items (
  id           bigint       GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  order_id     bigint       NOT NULL REFERENCES sales.orders(id) ON DELETE CASCADE,
  sku          text         NOT NULL,
  qty          integer      NOT NULL CHECK (qty > 0),
  unit_price   numeric(12,2) NOT NULL CHECK (unit_price >= 0)
);
CREATE INDEX order_items_order_idx ON sales.order_items (order_id);

-- Time-series table, partitioned by month (illustrative of Day 27 partman patterns)
CREATE TABLE sales.events (
  id       bigint       GENERATED ALWAYS AS IDENTITY,
  ts       timestamptz  NOT NULL,
  kind     text         NOT NULL,
  payload  jsonb        NOT NULL,
  PRIMARY KEY (id, ts)
) PARTITION BY RANGE (ts);

-- Create the current-month partition so INSERTs work out of the box.
DO $$
DECLARE
  first_of_month date := date_trunc('month', current_date)::date;
  next_month     date := (date_trunc('month', current_date) + interval '1 month')::date;
BEGIN
  EXECUTE format(
    'CREATE TABLE IF NOT EXISTS sales.events_%s PARTITION OF sales.events FOR VALUES FROM (%L) TO (%L)',
    to_char(first_of_month, 'YYYYMM'), first_of_month, next_month
  );
END $$;

CREATE INDEX events_kind_ts_idx ON sales.events (kind, ts DESC);

-- ---------------------------------------------------------------------
-- Default privileges — so future tables inherit correct grants
-- ---------------------------------------------------------------------
ALTER DEFAULT PRIVILEGES FOR ROLE app_deploy IN SCHEMA sales
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_rw;

ALTER DEFAULT PRIVILEGES FOR ROLE app_deploy IN SCHEMA sales
  GRANT SELECT ON TABLES TO app_ro;

ALTER DEFAULT PRIVILEGES FOR ROLE app_deploy IN SCHEMA sales
  GRANT USAGE, SELECT ON SEQUENCES TO app_rw;

-- Apply grants for existing tables too
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA sales TO app_rw;
GRANT SELECT                        ON ALL TABLES    IN SCHEMA sales TO app_ro;
GRANT USAGE, SELECT                 ON ALL SEQUENCES IN SCHEMA sales TO app_rw;

RESET ROLE;

-- ---------------------------------------------------------------------
-- Sample data
-- ---------------------------------------------------------------------

SET ROLE svc_app;

INSERT INTO sales.customers(email, full_name, tier, attributes)
SELECT
  format('user%s@example.com', g),
  format('User %s', g),
  (ARRAY['bronze','silver','gold','platinum'])[1 + (g % 4)],
  jsonb_build_object(
    'newsletter', (g % 3 = 0),
    'prefs', jsonb_build_object('theme', (ARRAY['light','dark'])[1 + (g % 2)])
  )
FROM generate_series(1, 500) g;

INSERT INTO sales.orders(customer_id, status, total, tags, ordered_at)
SELECT
  1 + (g % 500),
  (ARRAY['open','paid','shipped','cancelled'])[1 + (g % 4)],
  round((random() * 490 + 10)::numeric, 2),
  CASE
    WHEN g % 7 = 0 THEN ARRAY['discount']
    WHEN g % 5 = 0 THEN ARRAY['reorder']
    ELSE ARRAY['first']::text[]
  END,
  now() - (random() * interval '120 days')
FROM generate_series(1, 2000) g;

INSERT INTO sales.order_items(order_id, sku, qty, unit_price)
SELECT
  1 + (g % 2000),
  format('SKU-%04s', 1 + (g % 100)),
  1 + (g % 5),
  round((random() * 90 + 5)::numeric, 2)
FROM generate_series(1, 6000) g;

INSERT INTO sales.events(ts, kind, payload)
SELECT
  now() - (random() * interval '25 days'),
  (ARRAY['login','purchase','logout','error'])[1 + (g % 4)],
  jsonb_build_object('user_id', 1 + (g % 500), 'seq', g)
FROM generate_series(1, 5000) g;

RESET ROLE;

-- Give the planner accurate statistics right after bulk load.
ANALYZE sales.customers;
ANALYZE sales.orders;
ANALYZE sales.order_items;
ANALYZE sales.events;

-- Quick sanity view
SELECT 'customers'  AS relation, count(*) FROM sales.customers
UNION ALL SELECT 'orders',       count(*) FROM sales.orders
UNION ALL SELECT 'order_items',  count(*) FROM sales.order_items
UNION ALL SELECT 'events',       count(*) FROM sales.events;
