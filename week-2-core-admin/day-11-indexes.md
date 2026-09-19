# Day 11 — Indexes

## Objective

Pick the right PostgreSQL index type for each workload, create them online, and understand covering indexes, partial indexes, expression indexes, and index-only scans.

## SQL Server → PostgreSQL bridge

| SQL Server | PostgreSQL |
|---|---|
| Rowstore B-tree (clustered / nonclustered) | B-tree (default). No clustered index concept. |
| `INCLUDE` columns | `INCLUDE` in B-tree (PG 11+) |
| Filtered index (`WHERE`) | Partial index (`WHERE`) |
| Computed / persisted computed column indexed | Expression index (`CREATE INDEX ON t (lower(email))`) |
| Full-text index | GIN with `tsvector` |
| Spatial index | GiST / SP-GiST (PostGIS uses GiST) |
| Columnstore | Not built-in; use partitioning + BRIN, or Citus columnar, or AlloyDB |
| Online index rebuild | `CREATE INDEX CONCURRENTLY`, `REINDEX CONCURRENTLY` |
| `WITH (FILLFACTOR = 90)` | `WITH (fillfactor = 90)` — same |

## Concepts

### The five index access methods you use

| Type | Best for | Notes |
|---|---|---|
| **B-tree** | Equality and range on scalar types; sorting | Default. Supports `INCLUDE`. |
| **Hash** | Equality only, single column | WAL-logged since PG 10; rarely worth choosing over B-tree unless the type isn't sortable. |
| **GIN** | Membership in composite types: `jsonb`, `tsvector`, arrays, `hstore` | Bigger, slower to update; use `fastupdate`. |
| **GiST** | Geometric, range types, exclusion constraints, full-text (alt) | Balanced tree of "R-tree-ish" shapes. |
| **SP-GiST** | Non-balanced structures: quadtrees, tries, phone numbers | Niche. |
| **BRIN** | Very large, naturally clustered tables (append-only, time-series) | Tiny, cheap to maintain. |

### Partial and expression indexes

Two of the most under-used features by SQL Server converts.

```sql
-- Partial: only index active rows
CREATE INDEX orders_open_idx ON sales.orders (customer_id)
WHERE status = 'open';

-- Expression: query on lower(email) uses this
CREATE INDEX customers_email_lower ON sales.customers ((lower(email)));

-- Covering with INCLUDE (PG 11+)
CREATE INDEX orders_customer_covering
ON sales.orders (customer_id) INCLUDE (total, ordered_at);
```

### Index-only scans

If the query only needs columns present in the index, and the pages are marked "all-visible" in the visibility map (kept fresh by autovacuum), Postgres can skip the heap fetch entirely — an **index-only scan**. This is where `INCLUDE` shines and where regular `VACUUM` is essential.

### `CREATE INDEX CONCURRENTLY`

- Does **not** hold a blocking lock, so writes continue.
- Slower and reads the table twice.
- **Cannot** run inside a transaction block.
- On failure leaves an invalid index — check `pg_index.indisvalid`, drop, and retry.

Rule: in production, always `CONCURRENTLY`.

```sql
CREATE INDEX CONCURRENTLY orders_customer_status_idx
ON sales.orders (customer_id, status);
```

Rebuilding an existing index:

```sql
REINDEX INDEX CONCURRENTLY orders_customer_status_idx;
REINDEX TABLE CONCURRENTLY sales.orders;    -- all indexes on this table
```

### Multi-column index rules

Same rules SQL Server DBAs know: put the equality predicate columns first, range-scan column last, and match the order of your ORDER BY where possible. A composite `(a, b, c)` supports `WHERE a = ?`, `WHERE a = ? AND b = ?`, `WHERE a = ? AND b BETWEEN ...`, and `WHERE a = ? ORDER BY b, c`. It cannot skip `a`.

PG 12+ has **B-tree skip scan behavior** (via `bitmap heap scan` on the leading column) and can use trailing columns via bitmap ORed lookups; still, order matters.

### Sizing indexes

```sql
SELECT
  n.nspname||'.'||c.relname AS table,
  i.relname AS index,
  pg_size_pretty(pg_relation_size(i.oid)) AS size,
  idx_scan, idx_tup_read, idx_tup_fetch
FROM pg_stat_user_indexes s
JOIN pg_class i ON i.oid = s.indexrelid
JOIN pg_class c ON c.oid = s.relid
JOIN pg_namespace n ON n.oid = c.relnamespace
ORDER BY pg_relation_size(i.oid) DESC
LIMIT 20;

-- Unused indexes
SELECT relname AS index, idx_scan
FROM pg_stat_user_indexes
WHERE idx_scan = 0
ORDER BY pg_relation_size(indexrelid) DESC;
```

## Hands-on examples

```sql
-- Baseline
CREATE INDEX CONCURRENTLY idx_customers_email_lower
ON sales.customers ((lower(email)));

CREATE INDEX CONCURRENTLY idx_customers_attrs
ON sales.customers USING gin (attributes jsonb_path_ops);

-- Partial + covering
CREATE INDEX CONCURRENTLY idx_orders_open_by_customer
ON sales.orders (customer_id) INCLUDE (total, ordered_at)
WHERE status = 'open';

-- BRIN on an append-only fact table (time-series)
CREATE TABLE events(
  id bigint GENERATED ALWAYS AS IDENTITY,
  ts timestamptz NOT NULL,
  payload jsonb NOT NULL
) PARTITION BY RANGE (ts);
-- (partition creation elided)
CREATE INDEX ON events USING brin (ts) WITH (pages_per_range = 32);
```

### Prove an index-only scan

```sql
VACUUM ANALYZE sales.orders;
EXPLAIN (ANALYZE, BUFFERS)
SELECT customer_id, total, ordered_at
FROM sales.orders
WHERE customer_id = 1 AND status = 'open';
-- Look for "Index Only Scan using idx_orders_open_by_customer"
-- and "Heap Fetches: 0"
```

### Find missing-index candidates

PG doesn't have SQL Server's DMV suggestions. Two practical routes:

1. `pg_stat_statements` (day 25) — find slow queries and read their plans.
2. `hypopg` extension — hypothetical indexes: create one, replan, keep or drop.

```sql
CREATE EXTENSION IF NOT EXISTS hypopg;
SELECT * FROM hypopg_create_index('CREATE INDEX ON sales.orders(customer_id, status)');
EXPLAIN SELECT * FROM sales.orders WHERE customer_id=1 AND status='open';
SELECT hypopg_reset();
```

## Cloud notes

- All index features work on managed PG.
- Cloud performance dashboards ("Performance Insights", "Query Insights") surface most-scanned relations — use them to find high-value indexing targets.
- `pg_repack` and `pgstattuple` availability depends on the vendor's extension allowlist — check before assuming.

## Worksheet

1. Pick the right index for each situation:  
   a. `WHERE lower(email) = ?`  
   b. `WHERE tags @> ARRAY['discount']` on a big table  
   c. `WHERE ts >= now() - interval '1 day'` on a 5 TB append-only table  
   d. Full-text search in French  
   e. Exclusion constraint over overlapping time ranges  

2. Rewrite this SQL Server index in PG:  
   ```sql
   CREATE NONCLUSTERED INDEX ix_orders_status_customer
   ON dbo.Orders (Status, CustomerId) INCLUDE (Total, OrderedAtUTC)
   WHERE Status = 'open';
   ```  
   _Answer:_ …

3. A `CREATE INDEX CONCURRENTLY` failed last night. What's left behind and how do you clean up?  
   _Answer:_ …

4. Write a query that returns your top 10 largest **unused** indexes.  
   _Answer:_ …

5. Explain why keeping autovacuum healthy is essential for **index-only scans**.  
   _Answer:_ …

## References

- Index Types: https://www.postgresql.org/docs/current/indexes-types.html
- `CREATE INDEX`: https://www.postgresql.org/docs/current/sql-createindex.html
- `pg_stat_all_indexes`: https://www.postgresql.org/docs/current/monitoring-stats.html#MONITORING-PG-STAT-ALL-INDEXES-VIEW
- `hypopg`: https://hypopg.readthedocs.io/
