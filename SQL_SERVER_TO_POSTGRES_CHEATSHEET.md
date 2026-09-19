# SQL Server → PostgreSQL Cheatsheet

Keep this file open in a split pane for the whole 30 days. It's the fastest way to translate what you already know.

## 1. Terminology map

| SQL Server | PostgreSQL | Notes |
|---|---|---|
| Instance | Cluster (a.k.a. server, data directory) | One `postgres` process tree, one port, one `PGDATA`. |
| Database | Database | In PG, connections are scoped to *one* database — you cannot query across databases with a three-part name. Use schemas. |
| Schema (namespace) | Schema | Same idea. PG defaults to a schema called `public`; use `search_path` to control resolution. |
| Login | Role with `LOGIN` | Roles are unified: a role can be a user, a group, or both. |
| User (database user) | Role (granted into a DB) | See `GRANT CONNECT ON DATABASE`. |
| Filegroup | Tablespace | PG tablespaces are just directories, no filegroup-per-table sophistication. |
| MDF/LDF | `base/` + `pg_wal/` | Data files live under `PGDATA/base/<oid>/`; WAL lives in `PGDATA/pg_wal/`. |
| Transaction log | WAL (Write-Ahead Log) | Always on. `wal_level` controls how much detail. |
| Recovery model (FULL / BULK_LOGGED / SIMPLE) | `wal_level` + archiving choice | PG doesn't have SIMPLE. To get PITR, set `wal_level=replica` (or `logical`) and archive WAL. |
| SQL Server Agent | `pg_cron`, `pgAgent`, cloud schedulers | No built-in agent. Managed services usually give you one (see day 25 & cloud days). |
| SSMS | `psql` + pgAdmin + DBeaver + Azure Data Studio (with PG extension) | `psql` is the SQLCMD of PG and every DBA should master it. |
| DMVs (`sys.dm_*`) | `pg_stat_*` catalog views + `pg_stat_statements` | Day 12 & 25. |
| Query Store | `pg_stat_statements` (+ `auto_explain`, and vendor equivalents like RDS Performance Insights) | |
| Extended Events / Profiler | `log_statement`, `auto_explain`, `pgaudit` | |
| Maintenance plans | Autovacuum + cron/pg_cron/cloud scheduler | |
| Always On Availability Groups | Streaming replication + Patroni / repmgr / cloud-native HA | Managed services abstract this — days 17, 18, 22, 23. |
| Log shipping | WAL archiving + `pg_receivewal`, or logical replication | |
| Database Mirroring | Deprecated concept; use streaming replication | |
| Linked server | `postgres_fdw` (or `dblink`) | Foreign Data Wrappers are the general answer. |
| Service Broker | `LISTEN` / `NOTIFY`, or external brokers (Kafka, SNS/SQS, Pub/Sub) | |
| CLR | Untrusted languages: `plpython3u`, `plperlu`, C extensions | Rarely enabled on managed PG. |
| `IDENTITY` column | `GENERATED ... AS IDENTITY` (preferred) or `SERIAL`/`BIGSERIAL` | Use `IDENTITY` on PG 10+. |
| `TOP N` | `LIMIT N` (with `OFFSET`) | |
| `NOLOCK` / `READ UNCOMMITTED` | Not honored — PG's lowest isolation is `READ COMMITTED` | MVCC makes this a non-issue. |
| `sp_who2` / `sp_whoisactive` | `pg_stat_activity` | |
| `DBCC CHECKDB` | `amcheck` extension + backups + checksums | Enable data checksums at initdb. |
| `sp_help` | `\d`, `\d+`, `\dt`, `\df`, `\dv` in psql | |
| Temp table (`#t`) | `CREATE TEMP TABLE t` | Session-local; no shared TempDB. |
| Global temp table (`##t`) | `UNLOGGED TABLE` (approximate) | Not truly the same; usually redesign. |
| Table variable | `TEMP TABLE`, `WITH`(CTE), or arrays | |
| Clustered index | *No such thing* | `CLUSTER` reorganizes once; not maintained. Use fillfactor + covering indexes instead. |
| `INCLUDE` columns in nonclustered index | `INCLUDE` in B-tree (PG 11+) | Same keyword. |
| Filtered index | Partial index (`WHERE …`) | |
| Columnstore | Not built-in; use `citus` columnar, or Aurora/AlloyDB features | |
| In-Memory OLTP (Hekaton) | No direct equivalent | `UNLOGGED` tables, `pg_prewarm`, or specialized tools. |
| Change Data Capture (CDC) | Logical decoding + `wal2json`/`pgoutput`; managed CDC via DMS/Datastream | |
| Change Tracking | Custom triggers or logical replication | |
| Full-text search | Built-in tsvector/tsquery + GIN | Very good; day 27. |

## 2. T-SQL → PL/pgSQL & SQL syntax deltas

| T-SQL | PostgreSQL |
|---|---|
| `SELECT TOP 10 * FROM t` | `SELECT * FROM t LIMIT 10` |
| `ISNULL(a, b)` | `COALESCE(a, b)` (SQL standard) |
| `GETDATE()` | `now()` or `current_timestamp` |
| `SYSUTCDATETIME()` | `now() AT TIME ZONE 'UTC'` |
| `DATEADD(day, 7, dt)` | `dt + INTERVAL '7 days'` |
| `DATEDIFF(day, a, b)` | `(b::date - a::date)` |
| `CONVERT(varchar, x, 121)` | `to_char(x, 'YYYY-MM-DD HH24:MI:SS')` |
| `TRY_CAST` | `x::type` inside `BEGIN … EXCEPTION WHEN invalid_text_representation` |
| `IIF(cond, a, b)` | `CASE WHEN cond THEN a ELSE b END` |
| `STRING_AGG(col, ',')` | `string_agg(col, ',')` (same) |
| `NEWID()` | `gen_random_uuid()` (needs `pgcrypto` or PG 13+ has it built in) |
| `IDENTITY(1,1)` | `GENERATED ALWAYS AS IDENTITY` |
| `MERGE` | `MERGE` (PG 15+); or `INSERT ... ON CONFLICT DO UPDATE` |
| `BEGIN TRAN / COMMIT` | `BEGIN; ... COMMIT;` (same) |
| `PRINT 'x'` | `RAISE NOTICE 'x';` |
| `sp_executesql` | `EXECUTE format('...', ...)` in PL/pgSQL |
| `WITH (NOLOCK)` | remove; use appropriate isolation |
| Bracket identifiers `[col]` | Double-quoted `"col"` (case-sensitive!) |

## 3. Command equivalents

| Task | SQL Server | PostgreSQL |
|---|---|---|
| Connect from CLI | `sqlcmd -S host -d db -U u -P p` | `psql "host=host dbname=db user=u"` |
| List databases | `SELECT name FROM sys.databases` | `\l` or `SELECT datname FROM pg_database` |
| List tables | `SELECT * FROM sys.tables` | `\dt` or from `pg_catalog.pg_class` |
| Describe table | `sp_help 'schema.tbl'` | `\d+ schema.tbl` |
| Current connections | `sys.dm_exec_sessions` | `pg_stat_activity` |
| Kill session | `KILL <spid>` | `SELECT pg_terminate_backend(pid)` |
| Backup | `BACKUP DATABASE ...` | `pg_dump` (logical) or `pg_basebackup` (physical) |
| Restore | `RESTORE DATABASE ...` | `pg_restore` (logical) or file-system + WAL replay (physical) |
| Update stats | `UPDATE STATISTICS` | `ANALYZE` |
| Rebuild indexes | `ALTER INDEX ... REBUILD` | `REINDEX (CONCURRENTLY) INDEX ...` |
| Show query plan | `SET SHOWPLAN_ALL ON` / SSMS Ctrl+M | `EXPLAIN (ANALYZE, BUFFERS) ...` |

## 4. Configuration mental model

- SQL Server: `sp_configure`, trace flags, `SET` at session, database options.
- PostgreSQL: **hierarchy** — `postgresql.conf` → `ALTER SYSTEM` (writes `postgresql.auto.conf`) → `ALTER DATABASE`/`ALTER ROLE` SET → session `SET`. Some params require restart (`shared_buffers`, `max_connections`); most are reloadable with `pg_reload_conf()` or `SELECT pg_reload_conf()`.
- On managed services you almost never touch files — you use a **parameter group** (RDS/Aurora), **server parameter** (Azure), or **database flag** (Cloud SQL/AlloyDB).

## 5. Isolation and locking

| Concept | SQL Server default | PostgreSQL default |
|---|---|---|
| Isolation | `READ COMMITTED` (locking) | `READ COMMITTED` (MVCC — snapshot per statement) |
| Repeatable read | `REPEATABLE READ` (range locks) | `REPEATABLE READ` (snapshot per transaction, no phantoms via SSI) |
| Serializable | `SERIALIZABLE` (2PL) | `SERIALIZABLE` (SSI — optimistic, can throw `40001`) |
| Readers block writers? | With default RC + no RCSI: yes | Never — MVCC keeps prior row versions |

Practical: writers still block writers on the *same row*. Long-running transactions bloat the database because old row versions cannot be reclaimed. This is the #1 operational surprise (see days 6 and 10).

## 6. Managed service quick map

| Feature | AWS | Azure | GCP |
|---|---|---|---|
| Baseline offering | RDS for PostgreSQL | Azure Database for PostgreSQL – Flexible Server | Cloud SQL for PostgreSQL |
| Premium / distributed | Aurora PostgreSQL-Compatible | (Flexible Server HA) | AlloyDB for PostgreSQL |
| HA model | RDS Multi-AZ (standby) / Aurora storage-level | Zone-redundant HA (sync standby) | HA (regional, sync standby) / AlloyDB regional |
| Read replicas | RDS read replicas, Aurora replicas | Read replicas (async) | Read replicas / AlloyDB read pool |
| Backup style | Automated snapshots + WAL to S3 | Automated + geo-redundant option | Automated + PITR to 7–35 days |
| PITR window | Up to 35 days | 1–35 days | 1–35 days |
| Migration service | AWS DMS + Babelfish (SQL Server → Aurora PG) | Azure DMS + SSMA | Database Migration Service |
| Metrics | CloudWatch + Performance Insights + Enhanced Monitoring | Azure Monitor + Query Store on PG | Cloud Monitoring + Query Insights |
| Parameter tuning | Parameter group | Server parameters | Database flags |
| Extension approval | Per-instance parameter `rds.extensions` / Aurora allowlist | `azure.extensions` allowlist | `cloudsql.enable_pgaudit` etc. |
| SQL Server compat layer | **Babelfish for Aurora PostgreSQL** (accepts TDS + T-SQL) | None built-in | None built-in |

## 7. Things that will bite you

1. **`\c otherdb`** switches your `psql` session to another database — you cannot join tables across DBs.
2. **Case sensitivity.** Unquoted identifiers are folded to lowercase. `CREATE TABLE Foo` creates `foo`. Quote to preserve case, but then you must always quote.
3. **`NULL` sorting** — in PG, `NULLS LAST` for `ASC` is *not* the default; SQL Server puts NULLs first.
4. **No hints (mostly).** No `WITH (INDEX(...))`. There is `pg_hint_plan` extension, but the culture is to fix stats/queries.
5. **Autovacuum is essential**, not optional. Turning it off breaks production within days.
6. **DDL is transactional** in PG (mostly). You can wrap `CREATE INDEX`, `ALTER TABLE`, etc. in a transaction and roll back. Delightful.
7. **`CREATE INDEX CONCURRENTLY`** is what you always want in production. It cannot run inside a transaction block, though.
8. **Connection limits.** Managed PG has hard `max_connections` ceilings tied to instance size — use PgBouncer (day 13, 23).
9. **Roles are cluster-scoped.** Objects are database-scoped. Grants can be per-database, per-schema, per-object.
10. **`ANALYZE` after big loads.** Autovacuum eventually gets there, but not before your first bad plan.
