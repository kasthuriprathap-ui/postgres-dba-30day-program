# Day 13 — Parameter Tuning: the 15 That Matter

## Objective

Configure a PostgreSQL cluster (or a cloud parameter group) with sensible starting values for a typical OLTP or mixed workload. Understand memory, WAL, checkpoint, autovacuum, and planner parameters. Recognize the connection-count problem and choose PgBouncer or the vendor pooler.

## SQL Server → PostgreSQL bridge

| SQL Server | PostgreSQL |
|---|---|
| `max server memory` | `shared_buffers` + OS cache + `work_mem` + `maintenance_work_mem` |
| MAXDOP | `max_parallel_workers_per_gather`, `max_parallel_workers`, `max_worker_processes` |
| Cost threshold for parallelism | `min_parallel_table_scan_size`, `min_parallel_index_scan_size` |
| MAXOP for index build | `max_parallel_maintenance_workers` |
| Optimize for ad hoc / parameterization | Plan caching happens per prepared statement; no equivalent knob |
| tempdb configuration | `work_mem`, `temp_buffers`, `temp_tablespaces` |
| `sp_configure 'connections'` | `max_connections` |
| Query wait / lock wait | `lock_timeout`, `statement_timeout`, `deadlock_timeout` |
| Trace flag 4199 (planner fixes) | New PG versions ≈ new behavior automatically |

## Concepts

### The mental model

There are five knobs categories:

1. **Memory** — `shared_buffers`, `work_mem`, `maintenance_work_mem`, `effective_cache_size`, `wal_buffers`.
2. **WAL & checkpoint** — `wal_level`, `wal_compression`, `max_wal_size`, `min_wal_size`, `checkpoint_timeout`, `checkpoint_completion_target`, `synchronous_commit`.
3. **Autovacuum** — global scale factors and per-table overrides (day 10).
4. **Planner** — `random_page_cost`, `effective_io_concurrency`, `default_statistics_target`, `jit`.
5. **Concurrency & safety** — `max_connections`, `statement_timeout`, `idle_in_transaction_session_timeout`, `lock_timeout`, `deadlock_timeout`.

### Starting values for a mixed OLTP workload

Given a dedicated server with **R** = total RAM, **C** = vCPU count, on SSD:

| Parameter | Starting value | Why |
|---|---|---|
| `shared_buffers` | `R * 0.25` (up to ~32 GB) | Postgres buffer pool. Above ~32 GB, returns diminish; rely on OS page cache. |
| `effective_cache_size` | `R * 0.75` | Planner hint for total cache; doesn't allocate memory. |
| `work_mem` | `~R / max_connections / 4`, floor 4 MB, cap ~64 MB | Per-sort/hash, per-node, per-connection — multiplies fast. Use session-level bumps for reports. |
| `maintenance_work_mem` | `min(R/16, 2 GB)` | Larger = faster `CREATE INDEX`, `VACUUM`. |
| `wal_buffers` | `-1` (auto = 1/32 of shared_buffers, max 16 MB) | Auto is fine. |
| `wal_compression` | `on` | Cheap CPU win, less WAL volume. |
| `max_wal_size` | `4 GB` to `16 GB` | Bigger allows longer checkpoints, smoother writes. |
| `min_wal_size` | `1 GB` | Keeps a WAL pool to avoid file-create latency. |
| `checkpoint_timeout` | `15min` | Longer than default 5min smooths I/O; combine with larger `max_wal_size`. |
| `checkpoint_completion_target` | `0.9` | Spread checkpoint I/O; default already 0.9 in PG 14+. |
| `synchronous_commit` | `on` (or `remote_apply` w/ HA); `off` only when you accept losing the last N ms on crash | |
| `random_page_cost` | `1.1` on SSD/NVMe (default 4.0 is for spinning disks) | Encourages index scans. |
| `effective_io_concurrency` | `200` on SSD, `1` on spinning | Prefetch for bitmap heap scans. |
| `max_connections` | keep < 200; use PgBouncer beyond | Every connection = a process + memory. |
| `default_statistics_target` | `100` (default) → `500` for skewed columns | Larger = better plans, more `ANALYZE` cost. |
| `jit` | `on` (default) | Good for analytics; consider `off` for pure OLTP if CPU spikes. |
| `autovacuum_*` | Use per-table overrides (day 10). |
| `log_min_duration_statement` | `500ms` | Catch slow queries for post-mortems. |

Two rules of thumb:

- **You cannot fix a bad `work_mem` with `shared_buffers` and vice versa.** They serve different phases.
- **`max_connections` × `work_mem` × 2** should be well under RAM budget. In practice, cap `max_connections` and add a pooler.

### How to change parameters

```sql
-- Cluster-wide, persisted
ALTER SYSTEM SET work_mem = '32MB';
SELECT pg_reload_conf();

-- Which parameters need a restart?
SELECT name FROM pg_settings WHERE context = 'postmaster';

-- Per-database
ALTER DATABASE shop SET random_page_cost = 1.1;

-- Per-role
ALTER ROLE bi SET work_mem = '256MB';

-- Per-session
SET work_mem = '256MB';
```

### Connection pooling (PgBouncer)

Postgres forks a process per connection. On a small server, 100 connections is a lot. PgBouncer sits in front of the DB and multiplexes many client connections onto a smaller pool of server connections. Three modes:

| Mode | Reuse | Notes |
|---|---|---|
| `session` | Per client connection | Almost transparent; least memory savings. |
| `transaction` | Per transaction | **Recommended.** Most apps work; prepared statements need care. |
| `statement` | Per statement | Rare; no multi-statement transactions. |

Minimum config example:

```
[databases]
shop = host=127.0.0.1 dbname=shop

[pgbouncer]
listen_port = 6432
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = transaction
max_client_conn = 2000
default_pool_size = 25
```

Apps talk to `127.0.0.1:6432`; PgBouncer holds ~25 real connections to Postgres.

### Extensions to preload

```
shared_preload_libraries = 'pg_stat_statements,auto_explain'
```

Requires restart. Almost always worth it.

## Hands-on examples

### `pgtune`-style bootstrap

Suppose you have 8 vCPU, 32 GB RAM, SSD, "web" workload, ~100 connections:

```sql
ALTER SYSTEM SET shared_buffers = '8GB';
ALTER SYSTEM SET effective_cache_size = '24GB';
ALTER SYSTEM SET maintenance_work_mem = '2GB';
ALTER SYSTEM SET work_mem = '20MB';
ALTER SYSTEM SET wal_compression = 'on';
ALTER SYSTEM SET max_wal_size = '8GB';
ALTER SYSTEM SET checkpoint_timeout = '15min';
ALTER SYSTEM SET random_page_cost = 1.1;
ALTER SYSTEM SET effective_io_concurrency = 200;
ALTER SYSTEM SET max_connections = 150;
ALTER SYSTEM SET default_statistics_target = 100;
ALTER SYSTEM SET log_min_duration_statement = '500ms';
ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements,auto_explain';
-- shared_preload_libraries and max_connections need a restart
```

Verify:

```sql
SELECT name, setting, source, unit FROM pg_settings
WHERE name IN ('shared_buffers','work_mem','effective_cache_size',
               'random_page_cost','max_connections','shared_preload_libraries');
```

### Prove `work_mem` helps

```sql
-- Baseline
SET work_mem = '4MB';
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM (SELECT DISTINCT v FROM big) x;
-- Try again
SET work_mem = '64MB';
EXPLAIN (ANALYZE, BUFFERS) SELECT count(*) FROM (SELECT DISTINCT v FROM big) x;
-- Compare Sort Method: quicksort vs external merge Disk
```

## Cloud notes

- **RDS/Aurora**: parameters live in a **parameter group**. Static parameters require a reboot. RDS scales `shared_buffers` etc. based on instance size defaults — override only what you need. Aurora uses its own defaults optimized for its storage — resist over-tuning.
- **Azure Flexible Server**: **server parameters**. Some are locked by tier. `azure.extensions` allowlist controls which extensions you can `CREATE`.
- **Cloud SQL / AlloyDB**: **database flags**. AlloyDB has a subset of tunable flags; most defaults are ML-tuned.
- All three offer a **connection pooler** (RDS Proxy, Azure Flexible Server built-in PgBouncer, AlloyDB built-in) — prefer these over rolling your own.

## Worksheet

1. For each spec below, propose `shared_buffers`, `work_mem`, `max_connections`, and whether you'd add PgBouncer:  
   a. 4 vCPU / 16 GB / OLTP, 300 app connections.  
   b. 16 vCPU / 128 GB / mixed OLTP + reporting, 50 connections but occasional 20-way parallel scans.  
   c. 2 vCPU / 8 GB / dev/staging, ~10 connections.  

2. Write the `ALTER SYSTEM` block for scenario (a). Which params require a restart?  
   _Answer:_ …

3. Explain why you would set `random_page_cost = 1.1` on SSD but not on a spinning disk RAID.  
   _Answer:_ …

4. `work_mem = 256 MB` at cluster level with `max_connections = 500`. Estimate the worst-case memory. Would you accept this configuration?  
   _Answer:_ …

5. On RDS, name three parameters you cannot change and why.  
   _Answer:_ …

## References

- Runtime configuration: https://www.postgresql.org/docs/current/runtime-config.html
- `postgresqlco.nf` (annotated parameter reference): https://postgresqlco.nf/
- PgBouncer: https://www.pgbouncer.org/
