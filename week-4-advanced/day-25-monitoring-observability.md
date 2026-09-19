# Day 25 — Monitoring & Observability

## Objective

Build a monitoring stack for PostgreSQL that answers three questions instantly: "Is it up?", "Is it healthy?", "What's slow right now?". Use `pg_stat_statements`, `auto_explain`, and per-cloud dashboards; export metrics with `postgres_exporter` if you self-host.

## SQL Server → PostgreSQL bridge

| SQL Server | PostgreSQL |
|---|---|
| DMVs (`sys.dm_*`) | `pg_stat_*` views |
| Query Store | `pg_stat_statements` + `auto_explain` |
| Extended Events | `pgaudit`, `auto_explain`, log-based analysis |
| SQL Server Agent alerts | Cloud alerts + Alertmanager |
| PerfMon counters | `postgres_exporter` → Prometheus |
| Wait stats | `pg_stat_activity.wait_event_type / wait_event` |
| SSMS Activity Monitor | `pg_stat_activity` + a live query view |

## The three-view mental model

**1. Availability**: is the DB accepting connections and completing queries?
**2. Health / capacity**: CPU, memory, IO, WAL, replication lag, autovacuum health.
**3. Query performance**: top statements, plans, temp file usage, cache hit ratio.

## Key `pg_stat_*` views

| View | What it tells you |
|---|---|
| `pg_stat_activity` | Live sessions, current query, wait events. |
| `pg_stat_database` | Per-DB: tuples fetched/inserted/updated/deleted, blocks read/hit, deadlocks, temp bytes. |
| `pg_stat_user_tables` | Per-table: seq_scan, idx_scan, n_live_tup, n_dead_tup, last_autovacuum. |
| `pg_stat_user_indexes` | idx_scan, idx_tup_read, idx_tup_fetch — great for unused indexes. |
| `pg_stat_statements` | Top statements by exec time / IO / calls (extension). |
| `pg_stat_bgwriter` (PG16 splits) | Background writer/checkpoint activity. |
| `pg_stat_wal` | WAL bytes written, records, buffer full. |
| `pg_stat_replication` | Streaming replicas + lag. |
| `pg_stat_ssl` | Which sessions are SSL-encrypted. |

Reset counters when you start a benchmark: `SELECT pg_stat_reset()` or `pg_stat_statements_reset()`.

## `pg_stat_statements` — the top query view

Enable via `shared_preload_libraries` + `CREATE EXTENSION pg_stat_statements`. Then:

```sql
SELECT
  substring(query, 1, 80) AS query,
  calls,
  round(total_exec_time)::bigint AS total_ms,
  round(mean_exec_time)::bigint  AS mean_ms,
  round(stddev_exec_time)::bigint AS stddev_ms,
  rows,
  shared_blks_hit + shared_blks_read AS blocks_touched,
  round(100.0 * shared_blks_hit / NULLIF(shared_blks_hit + shared_blks_read, 0), 1) AS hit_pct
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 20;
```

Correlate with `pg_stat_activity` (live) and `auto_explain` (plans in logs).

## `auto_explain` — plans without effort

```
shared_preload_libraries = 'auto_explain,pg_stat_statements'
auto_explain.log_min_duration = '500ms'
auto_explain.log_analyze      = on
auto_explain.log_buffers      = on
auto_explain.log_format       = 'json'
```

Every slow query logs its plan. Feed the JSON to a log tool for search.

## Self-hosted observability stack

```
  Postgres  ──(exporter)──▶ Prometheus ──▶ Grafana
     │                         │
     └──▶ logs ──▶ Loki/ELK ──▶ Grafana
```

- **postgres_exporter** — https://github.com/prometheus-community/postgres_exporter
- Grafana dashboards — search "PostgreSQL" on grafana.com; ID 9628 and 12485 are common starts.
- Ship logs via `promtail`, Fluent Bit, or the platform's agent.

## Cloud-native observability

- **AWS**
  - **CloudWatch**: 50+ RDS metrics (CPUUtilization, DatabaseConnections, FreeableMemory, ReadIOPS, WriteIOPS, ReplicaLag, FreeStorageSpace, MaximumUsedTransactionIDs).
  - **Enhanced Monitoring**: per-process OS stats (1–60 s cadence).
  - **Performance Insights**: DB load by wait type, top SQL, top hosts, top users. 7-day retention free; 24 months paid.
  - **RDS Events**: DNS repoints, snapshot lifecycle, replica lag.

- **Azure**
  - **Azure Monitor** metrics and Log Analytics (Kusto).
  - **Query Store on Flexible Server** (extension `pg_qs`, Query Performance Insight in portal).
  - **Diagnostic settings** — export PG logs and metrics.

- **GCP**
  - **Cloud Monitoring** metrics per instance.
  - **Query Insights**: top queries, per-query plans, application tags.
  - **Cloud Logging** for slow queries.
  - **system_insights**/`log_statement` config for AlloyDB.

## Alerts you actually want

| Alert | Threshold |
|---|---|
| Instance unreachable | 2 min |
| CPU > 85% for 10 min | steady load, not spikes |
| FreeableMemory < 10% | ~ |
| FreeStorageSpace < 15% | ~ |
| DatabaseConnections > 90% of max | pooler alarm |
| Replica lag > 30 s | tune to your RPO |
| Oldest transaction age > 15 min | ties into autovacuum |
| Autovacuum has not run on a hot table in > 2× normal interval | ~ |
| Deadlock rate > baseline | investigate |
| Failed logins spike | security |
| WAL usage > 50 GB (or your budget) | slot pinned? |

## Wait events — the fast triage tool

```sql
SELECT wait_event_type, wait_event, count(*) 
FROM pg_stat_activity
WHERE state = 'active'
GROUP BY 1,2
ORDER BY 3 DESC;
```

Rules of thumb:

- `IO/DataFileRead` — you're missing indexes or shared_buffers is too small.
- `Lock/transactionid` — waiting on a row-level lock; another transaction holds it.
- `Lock/relation` — an `ACCESS EXCLUSIVE`-holding statement (DDL) is queued.
- `LWLock/BufferMapping` — buffer manager contention, huge tables.
- `Client/ClientRead` — waiting on the client to send more; often the app is slow.
- `Activity/…` — idle backends; not interesting.

## Hands-on

Add these queries to your `.psqlrc`-adjacent snippets:

```sql
-- Slowest current queries
SELECT pid, state, wait_event, now()-query_start AS runtime,
       left(query, 120) FROM pg_stat_activity
WHERE state <> 'idle' ORDER BY runtime DESC NULLS LAST;

-- Oldest transaction
SELECT pid, usename, state, xact_start, now()-xact_start AS xact_age, left(query, 120)
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
ORDER BY xact_age DESC LIMIT 5;

-- Top statements
SELECT query, calls, total_exec_time, mean_exec_time
FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 10;

-- Cache hit ratio (aim > 99%)
SELECT sum(heap_blks_hit)::float / NULLIF(sum(heap_blks_hit + heap_blks_read),0)
FROM pg_statio_user_tables;
```

Wire them into a Grafana dashboard or a Slack `/pg` bot for on-call.

## Worksheet

1. On your RDS lab, enable `pg_stat_statements` and produce the top-5 by mean_exec_time. Which is the worst offender?  
   _Answer:_ …

2. Pick five alerts from the list above and set defensible thresholds for your workload.  
   _Answer:_ …

3. Write a query that returns the top 10 tables by dead-tuple percentage and their last autovacuum time. This is your "vacuum health" dashboard.  
   _Answer:_ …

4. Explain why `Client/ClientRead` waits usually aren't a Postgres problem.  
   _Answer:_ …

5. Bonus: what's the difference between `pg_stat_bgwriter` (PG15 and earlier) and `pg_stat_checkpointer` + `pg_stat_bgwriter` (PG17)? What did it split?  
   _Answer:_ …

## References

- Monitoring stats: https://www.postgresql.org/docs/current/monitoring-stats.html
- `pg_stat_statements`: https://www.postgresql.org/docs/current/pgstatstatements.html
- `postgres_exporter`: https://github.com/prometheus-community/postgres_exporter
- Grafana PG dashboards: https://grafana.com/grafana/dashboards/?search=postgres
