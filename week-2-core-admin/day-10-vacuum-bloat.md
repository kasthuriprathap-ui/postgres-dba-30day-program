# Day 10 — VACUUM, Autovacuum, Bloat, and Freeze

## Objective

Diagnose bloat, measure it, tune autovacuum for a hot table, and understand the transaction-id wraparound risk. This is the topic that surprises SQL Server DBAs the most.

## SQL Server → PostgreSQL bridge

| SQL Server | PostgreSQL |
|---|---|
| Statistics auto-update | `ANALYZE` and autovacuum's `ANALYZE` phase |
| Ghost record cleanup | Not analogous; MVCC + VACUUM cleans dead tuples |
| Index defragmentation | `REINDEX (CONCURRENTLY) INDEX ...` — day 11 |
| Shrink DB (usually a bad idea) | `VACUUM FULL` (rewrites the table, holds `ACCESS EXCLUSIVE`) |
| N/A | `pg_repack` extension — online reorganization |
| Log truncation | Not related |

## Concepts

### What VACUUM does

For a table, `VACUUM`:

1. Scans pages, finds tuples that are no longer visible to any transaction.
2. Marks that space as reusable **in-place** (does not shrink the file).
3. Updates the **visibility map** (VM) so index-only scans can skip fetching from heap.
4. Optionally runs `ANALYZE` (autovacuum does both when triggered).
5. Advances `relfrozenxid`/`relminmxid` if it does a "freeze" (see wraparound below).

`VACUUM` does **not** by itself return disk to the OS. `VACUUM FULL` does, but requires an `ACCESS EXCLUSIVE` lock and rewrites the whole table.

### Autovacuum in one page

- Runs `max_worker_processes` autovacuum workers, throttled by cost limits.
- Triggers per-table when:
  - `n_dead_tup > autovacuum_vacuum_threshold + autovacuum_vacuum_scale_factor * n_live_tup`
  - or `n_ins_since_vacuum > autovacuum_vacuum_insert_threshold + autovacuum_vacuum_insert_scale_factor * n_live_tup` (PG 13+)
- Also runs `ANALYZE` on similar thresholds.
- Cost-based throttle: `autovacuum_vacuum_cost_limit` (per worker) and `autovacuum_vacuum_cost_delay` (default 2ms in PG 12+ — much more aggressive than earlier defaults).

Defaults are reasonable for small tables and terrible for hot ones. Common pattern: override per table.

```sql
ALTER TABLE sales.orders SET (
  autovacuum_vacuum_scale_factor = 0.02,
  autovacuum_analyze_scale_factor = 0.01,
  autovacuum_vacuum_cost_limit = 2000
);
```

### Bloat

**Bloat** is space consumed by dead tuples not yet reused (or by an oversized table file after many `UPDATE`/`DELETE` bursts). It slows down sequential scans, index scans (indirectly), and increases memory pressure.

Common causes:

1. **Long-running transactions** — pinning the xmin horizon so no one can be cleaned up.
2. **Long-open replication slots** — an inactive logical replication slot keeps WAL and prevents cleanup at the source.
3. **Autovacuum too slow** on hot tables — cost limit too low, or workers too few.
4. **Bulk `UPDATE` on a huge table** — creates a burst of dead tuples that outpaces autovacuum.
5. **`fillfactor` = 100 on a hot table with HOT updates** — no room for HOT chain to reuse the same page.

### Transaction ID wraparound

PG uses 32-bit transaction ids. To avoid wraparound, VACUUM periodically **freezes** old tuples (marks them as "visible to everyone forever"). If your database goes too long without freeze, PG will refuse to allocate new xids ("must vacuum to prevent wraparound") — the database goes read-only until you vacuum.

Autovacuum kicks in aggressively when `age(relfrozenxid) > autovacuum_freeze_max_age` (default 200 million). You should never see wraparound if autovacuum is running, but you *can* see it if something (like a long-held lock, or `autovacuum = off`) prevents it.

## Hands-on examples

### Measure bloat quickly

```sql
-- Dead-tuple ratio per table (autovacuum's own view)
SELECT schemaname||'.'||relname AS table,
       n_live_tup, n_dead_tup,
       round(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 1) AS dead_pct,
       last_autovacuum, last_vacuum
FROM pg_stat_user_tables
ORDER BY dead_pct DESC NULLS LAST
LIMIT 20;
```

More precise (with `pgstattuple`):

```sql
CREATE EXTENSION IF NOT EXISTS pgstattuple;
SELECT * FROM pgstattuple('sales.orders');       -- warning: reads the whole table
SELECT * FROM pgstattuple_approx('sales.orders'); -- sampled, cheap
```

### Simulate bloat

```sql
CREATE TABLE bloat_demo(id serial primary key, v text);
INSERT INTO bloat_demo(v) SELECT repeat('x', 200) FROM generate_series(1, 200000);
SELECT pg_size_pretty(pg_relation_size('bloat_demo'));
-- Update every row 5 times
UPDATE bloat_demo SET v = v || '.' ;
UPDATE bloat_demo SET v = v || '.' ;
UPDATE bloat_demo SET v = v || '.' ;
SELECT pg_size_pretty(pg_relation_size('bloat_demo'));  -- much larger
VACUUM (VERBOSE, ANALYZE) bloat_demo;
SELECT pg_size_pretty(pg_relation_size('bloat_demo'));  -- unchanged; space reused later
VACUUM FULL bloat_demo;                                  -- rewrite
SELECT pg_size_pretty(pg_relation_size('bloat_demo'));  -- shrunk
```

### `pg_repack` — online reorganization

```
CREATE EXTENSION pg_repack;
pg_repack -h HOST -U postgres -d shop -t sales.orders
```

Requires primary key or unique index. Copies data to a shadow table with a trigger, swaps at the end. No long `ACCESS EXCLUSIVE` on production.

### Autovacuum introspection

```sql
-- Current autovacuum activity
SELECT pid, datname, relname, phase, heap_blks_scanned, heap_blks_total,
       (heap_blks_scanned::numeric / NULLIF(heap_blks_total,0)) AS pct
FROM pg_stat_progress_vacuum
LEFT JOIN pg_class c ON c.oid = relid;
```

Force a vacuum with logging to see what's happening:

```sql
SET client_min_messages = 'log';
VACUUM (VERBOSE, ANALYZE) sales.orders;
```

Tuning for a hot table:

```sql
ALTER TABLE sales.orders SET (
  autovacuum_vacuum_scale_factor = 0.01,      -- fire at 1% dead
  autovacuum_analyze_scale_factor = 0.01,
  autovacuum_vacuum_cost_limit = 5000,        -- more IO per round
  fillfactor = 90                             -- leave 10% headroom for HOT
);
```

## Cloud notes

- **RDS/Aurora**: autovacuum is on and you can override per-instance defaults via a parameter group and per-table via `ALTER TABLE`. Enhanced Monitoring shows autovacuum I/O.
- **Azure Flexible Server**: same. Set server parameters `autovacuum_vacuum_cost_limit`, etc.
- **Cloud SQL / AlloyDB**: database flags. AlloyDB adds a columnar engine but heap autovacuum is unchanged.
- Every managed service has an alarm you should have on: **long-running transactions** and **oldest xmin age**. Add them on day 25.

## Worksheet

1. In one sentence each:
   a. Why doesn't `VACUUM` return space to the OS?  
   b. Why doesn't `VACUUM FULL` fit in a live-production maintenance window on a 500 GB table?  

2. A table has `n_dead_tup = 12M`, `n_live_tup = 3M`, `last_autovacuum` was 4 hours ago. What are the three most likely causes?  
   _Answer:_ …

3. Write the per-table autovacuum overrides for a very hot append+update `events` table with 50 M rows and 100 K updates/hour.  
   _Answer:_ …

4. Bonus: write a query that lists the current oldest xmin in the cluster and which backend is holding it.  
   _Answer:_ …

5. On RDS, list two CloudWatch metrics that are early warnings for autovacuum starvation.  
   _Answer:_ …

## References

- Routine Vacuuming: https://www.postgresql.org/docs/current/routine-vacuuming.html
- Autovacuum: https://www.postgresql.org/docs/current/runtime-config-autovacuum.html
- `pg_repack`: https://reorg.github.io/pg_repack/
