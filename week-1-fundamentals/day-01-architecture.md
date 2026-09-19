# Day 1 — PostgreSQL Architecture & Mental Model

## Objective

By the end of today you can describe, on a whiteboard, how a PostgreSQL cluster is organized, what happens when a client connects, and how it differs from a SQL Server instance.

## SQL Server → PostgreSQL bridge

| SQL Server | PostgreSQL | One-line summary |
|---|---|---|
| Instance (`MSSQLSERVER`) | Cluster / server | One `postgres` daemon, one TCP port, one `PGDATA` directory. |
| Database | Database | Same word, different scope — you cannot join across DBs. |
| Schema | Schema | Same word, same idea. Default schema is `public`. |
| `master`, `msdb`, `tempdb`, `model` | `postgres`, `template0`, `template1` | Only `postgres` is a working DB; `template*` are copy sources. There is no shared TempDB. |
| SQLOS scheduler | OS + one **process per connection** | PG forks a new backend process per connection. This is why connection pooling matters. |
| MDF/LDF | `base/` + `pg_wal/` | Data files in `PGDATA/base/<db-oid>/<relfilenode>`; WAL in `PGDATA/pg_wal/`. |
| Buffer pool | shared_buffers | Usually 25% of RAM on a dedicated server. |

## Concepts

### Processes, not threads

Postgres uses a multi-process architecture. The **postmaster** listens on the port; for every connection it `fork()`s a **backend** process. Background workers handle jobs:

- `background writer` — flushes dirty buffers gradually
- `checkpointer` — writes all dirty buffers at checkpoint boundaries
- `WAL writer` — flushes WAL buffers
- `autovacuum launcher` + workers — reclaim dead tuple space
- `logical/physical replication workers`
- `stats collector` / `pgstat` (implementation changed in PG15)
- `archiver` — copies completed WAL files to your archive when `archive_mode=on`

Because each backend is a process, **connections are expensive** (memory + fork cost). Rule of thumb: for anything above ~200 concurrent connections use a pooler (PgBouncer). On managed services this is baked in or documented; see day 13 and day 23.

### The storage hierarchy

```
Cluster  (one running postgres, one PGDATA, one port)
  ├── Database: postgres      ← default admin/landing DB
  ├── Database: template0     ← pristine copy source, do not modify
  ├── Database: template1     ← default template for CREATE DATABASE
  └── Database: your_app
        ├── Schema: public
        ├── Schema: reporting
        └── Schema: audit
              ├── Table: audit.event
              ├── Index: audit.idx_event_ts
              └── View, sequence, function, ...
```

Objects live inside a database. Roles (users) live at the cluster level. Grants are per-object.

### WAL — the "transaction log", but always on

- Every change writes a WAL record *before* the data page changes.
- WAL is durable — `fsync=on` (default) guarantees a committed transaction survives crash.
- WAL is also the substrate for **crash recovery**, **PITR**, **streaming replication**, and **logical replication**.
- `wal_level` (`minimal` / `replica` / `logical`) controls how much info is written. Managed PG almost always uses `replica` or `logical`.

### Checkpoints

A checkpoint flushes all dirty buffers to disk so that WAL prior to the checkpoint is no longer needed for crash recovery. Controlled by `checkpoint_timeout` (default 5 min) and `max_wal_size` (default 1 GB). Contrast with SQL Server automatic checkpoints — the mechanics differ but the *why* is the same.

### The catalog

`pg_catalog` is the equivalent of `sys.*`. Useful entrypoints:

- `pg_database`, `pg_namespace` (schemas), `pg_class` (tables/indexes/views/sequences), `pg_attribute` (columns), `pg_index`, `pg_stat_activity`, `pg_stat_user_tables`, `pg_settings`, `pg_roles`, `pg_authid`.
- The `information_schema.*` views are the SQL-standard portable version.

## Hands-on examples

Assuming you have a `psql` shell open (Day 2 sets this up if you don't):

```sql
-- Where does this cluster live and what version?
SHOW data_directory;
SHOW server_version;

-- What databases exist?
SELECT datname, pg_size_pretty(pg_database_size(datname)) AS size
FROM pg_database
ORDER BY 1;

-- What's my current context?
SELECT current_database(), current_user, current_schema(), inet_server_addr(), inet_server_port();

-- Who is connected right now?
SELECT pid, usename, datname, state, wait_event_type, wait_event,
       age(now(), xact_start) AS xact_age, query
FROM pg_stat_activity
WHERE backend_type = 'client backend';

-- How big is shared_buffers?
SHOW shared_buffers;

-- What are all the background workers doing?
SELECT pid, backend_type, state FROM pg_stat_activity WHERE backend_type <> 'client backend';
```

Compare against SQL Server:

```sql
-- SQL Server equivalents (for muscle memory)
SELECT SERVERPROPERTY('ProductVersion');
SELECT name, size*8/1024 AS size_mb FROM sys.master_files;
SELECT * FROM sys.dm_exec_sessions;
```

## Cloud notes

- **AWS RDS / Aurora**: `data_directory` is not visible; you never see `PGDATA`. You interact with the cluster only through the API, `psql`, and CloudWatch. `pg_stat_activity` still works.
- **Azure Flexible Server**: similar — no filesystem access. Server parameters replace `postgresql.conf`.
- **GCP Cloud SQL / AlloyDB**: same story. AlloyDB adds its own columnar engine, but the SQL surface is standard PG.

Managed = same engine, hidden filesystem, curated set of extensions and parameters.

## Worksheet

Answer in your own notebook (or fill in below):

1. In your own words, describe why "one connection = one process" changes how you size a PG server versus a SQL Server instance.  
   _Answer:_ …

2. A colleague says "I'll just put table A in database A and table B in database B and JOIN them." What do you tell them?  
   _Answer:_ …

3. You run `SELECT count(*) FROM pg_stat_activity WHERE state = 'idle in transaction';` on a production box and see 42 rows. Why is this alarming? (Foreshadow of day 6/10.)  
   _Answer:_ …

4. Map each of these SQL Server things to their PG equivalent:  
   a. `tempdb` → …  
   b. `sys.dm_exec_sessions` → …  
   c. `BACKUP LOG` → …  
   d. Filegroup → …  

5. Extra credit: on a Linux host, list five processes you would expect to see for a healthy idle cluster.  
   _Answer:_ …

## References

- PostgreSQL docs — "Internals" chapter: https://www.postgresql.org/docs/current/internals.html
- `pg_stat_activity`: https://www.postgresql.org/docs/current/monitoring-stats.html
- "PostgreSQL Architecture" (interactive diagram): https://www.interdb.jp/pg/
