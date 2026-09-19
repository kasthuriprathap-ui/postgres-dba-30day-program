# Day 12 — Reading Query Plans with EXPLAIN

## Objective

Read a PostgreSQL execution plan the way you read a SQL Server actual plan. Recognize the common scan/join/aggregate operators, understand where estimates go wrong, and know when to intervene versus fix statistics.

## SQL Server → PostgreSQL bridge

| SQL Server | PostgreSQL |
|---|---|
| Estimated / actual execution plan | `EXPLAIN` / `EXPLAIN ANALYZE` |
| Include actual execution plan | `EXPLAIN (ANALYZE, BUFFERS)` |
| Show XML plan | `EXPLAIN (FORMAT JSON)` or `(FORMAT XML)` |
| Query Store | `pg_stat_statements` + `auto_explain` |
| Missing index hint (from DTA/DMVs) | `hypopg` extension + your judgment |
| Query hints (`OPTION (LOOP JOIN)`) | Very few, discouraged: `enable_nestloop = off`, `pg_hint_plan` |
| Cardinality Estimator versions | `default_statistics_target`, per-column `SET STATISTICS`, extended statistics |

## Concepts

### `EXPLAIN` options

```
EXPLAIN                                  -- estimated only, does not run
EXPLAIN ANALYZE                          -- runs and returns actual timings
EXPLAIN (ANALYZE, BUFFERS)               -- add I/O counters — you almost always want this
EXPLAIN (ANALYZE, BUFFERS, SETTINGS)     -- + which non-default GUCs are in play
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)      -- + output column details
EXPLAIN (ANALYZE, BUFFERS, WAL)          -- + how much WAL the query wrote (for DML)
EXPLAIN (FORMAT JSON) SELECT ...;        -- machine-readable
```

Warning: `EXPLAIN ANALYZE` runs the query for real. Wrap it in a transaction and roll back if it's a mutation:

```sql
BEGIN;
EXPLAIN (ANALYZE, BUFFERS) DELETE FROM x WHERE ...;
ROLLBACK;
```

### Plan operators you'll see

**Scans**

- `Seq Scan` — read the whole table. Fine on small tables or when you actually want most rows.
- `Index Scan` — traverse the B-tree, fetch rows from heap in index order.
- `Index Only Scan` — index has all needed columns, VM says pages are all-visible. Zero heap fetches, ideal.
- `Bitmap Index Scan` + `Bitmap Heap Scan` — build a bitmap of matching TIDs, then read heap in physical order. Faster than plain index scan when many rows match.
- `CTE Scan`, `Function Scan`, `Values Scan`, `Foreign Scan` — special sources.

**Joins**

- `Nested Loop` — for each outer row, probe inner. Optimal for small outer + indexed inner.
- `Hash Join` — build hash of the smaller side, probe with larger. Optimal for large joins on equality.
- `Merge Join` — both sides sorted on the join key. Optimal for very large sorted inputs, and for range joins.

**Aggregation and sort**

- `HashAggregate` — hash-based grouping. Cheap when the group set fits in `work_mem`.
- `GroupAggregate` — after a sort. Used when you need ordered groups or when hash aggregate can't fit memory.
- `Sort` — quicksort in memory, external merge sort on disk. Watch for "Sort Method: external merge Disk: ...kB" — bump `work_mem`.
- `Materialize` — cache a rescan-target.
- `Memoize` (PG 14+) — a small LRU inside a nested loop. Great sign in random-access joins.

**Parallelism**

- `Gather`, `Gather Merge` — combine parallel workers' output.
- `Parallel Seq Scan`, `Parallel Index Scan`, `Parallel Hash Join` — parallel counterparts.

### Reading a plan

Rows are estimated (`rows=`) vs actual (`actual rows=`). Big deltas here are usually your problem:

```
Seq Scan on orders  (cost=0.00..12345 rows=100 width=32) (actual time=0.02..2.15 rows=987654 loops=1)
```

Estimated 100, got ~1 M — bad stats or a correlation the planner can't see. Options:

1. `ANALYZE` — refresh single-column stats.
2. `ALTER TABLE t ALTER COLUMN c SET STATISTICS 1000;` — more histograms.
3. `CREATE STATISTICS s (dependencies, ndistinct) ON a, b FROM t;` — **extended statistics** — for correlated columns.
4. Add / adjust index.
5. Rewrite the query (subquery-flatten, avoid `NOT IN` with nullable columns, etc.).

### `auto_explain` — passive plan logging

```
shared_preload_libraries = 'auto_explain,pg_stat_statements'
auto_explain.log_min_duration = '500ms'
auto_explain.log_analyze = on
auto_explain.log_buffers = on
auto_explain.log_verbose = on
auto_explain.log_format = 'json'
```

Every slow query dumps its plan to the log. Priceless.

### Cost model, briefly

Cost is a made-up unit; what matters is that the planner compares two plans consistently. Key parameters (day 13):

- `seq_page_cost` (1.0)
- `random_page_cost` (4.0; drop to `1.1` on SSD)
- `cpu_tuple_cost`, `cpu_index_tuple_cost`, `cpu_operator_cost`
- `effective_cache_size` — the planner's guess at OS + shared_buffers cache. Set to ~75% of RAM.

## Hands-on examples

Load some data first:

```sql
CREATE TABLE big(id serial PRIMARY KEY, k int NOT NULL, v text);
INSERT INTO big(k,v)
SELECT (random()*10000)::int, md5(g::text)
FROM generate_series(1, 1000000) g;
CREATE INDEX ON big(k);
VACUUM ANALYZE big;
```

### 1. Compare plans

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM big WHERE k = 42;

EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM big WHERE k BETWEEN 1 AND 100;

EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM big WHERE v LIKE 'abc%';
```

Note when it flips from `Index Scan` to `Bitmap Heap Scan` to `Seq Scan` as the predicate becomes less selective.

### 2. Force a plan (rarely — for learning)

```sql
SET enable_seqscan = off;
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM big;
RESET enable_seqscan;
```

### 3. Fix a bad estimate with extended stats

```sql
CREATE TABLE ab(a int, b int);
INSERT INTO ab SELECT g%10, g%10 FROM generate_series(1,100000) g;   -- a and b perfectly correlated
ANALYZE ab;

EXPLAIN SELECT * FROM ab WHERE a=3 AND b=3;
-- planner assumes independence → underestimates rows

CREATE STATISTICS ab_stat (dependencies, ndistinct) ON a,b FROM ab;
ANALYZE ab;
EXPLAIN SELECT * FROM ab WHERE a=3 AND b=3;
-- rows estimate is now close to actual
```

### 4. Detect an on-disk sort

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM big ORDER BY v;
-- Look for "Sort Method: external merge Disk: 40MB"

SET work_mem = '256MB';
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM big ORDER BY v;
-- Now "Sort Method: quicksort Memory: ..."
```

### 5. Compare against `pg_stat_statements` (day 25 preview)

```sql
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SELECT query, calls, mean_exec_time, rows
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 20;
```

## Cloud notes

- **RDS Performance Insights** and **Aurora Query Plan Management** surface plans and top waits without you enabling anything else.
- **Azure**: Flexible Server has a Query Store extension (`pg_qs`) and Query Performance Insight in the portal.
- **Cloud SQL / AlloyDB**: **Query Insights** shows per-query plans, top waits, and per-user usage.

## Worksheet

1. Given this plan snippet, what's likely wrong and how would you address it?  
   ```
   Nested Loop  (rows=10 actual rows=250000)
     -> Seq Scan on big (rows=1 actual rows=250000)
   ```  
   _Answer:_ …

2. Enable `auto_explain` on your lab cluster to log any query over 250 ms with buffers and plans. Paste the parameter block.  
   _Answer:_ …

3. Two columns `country_code` and `currency_code` are highly correlated. Write the DDL to teach the planner about this.  
   _Answer:_ …

4. Bonus: When would you accept a `Seq Scan` even if an index exists?  
   _Answer:_ …

5. Convert this SQL Server habit to PG: "always look at estimated vs actual row counts and worry when they differ by more than 10x." What do you look for in a PG plan?  
   _Answer:_ …

## References

- Using `EXPLAIN`: https://www.postgresql.org/docs/current/using-explain.html
- Extended statistics: https://www.postgresql.org/docs/current/planner-stats.html#PLANNER-STATS-EXTENDED
- `auto_explain`: https://www.postgresql.org/docs/current/auto-explain.html
- Depesz's plan explainer: https://explain.depesz.com/
- pev / pgMustard visualizers: https://explain.dalibo.com/, https://www.pgmustard.com/
