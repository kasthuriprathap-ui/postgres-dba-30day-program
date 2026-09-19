# Day 26 — Migrating from SQL Server to PostgreSQL

## Objective

Plan and execute a migration from SQL Server to a managed PostgreSQL. Understand the two dominant paths — **schema conversion + logical migration** and **Babelfish (T-SQL on Aurora)** — and produce a runbook.

## The three families of migration

1. **Full refactor** — rewrite the schema and app code to native PostgreSQL. Highest cost, best long-term.
2. **Schema conversion + data migration** — automated schema translation (AWS SCT / Azure DMA / SSMA) then bulk + CDC load with DMS/Datastream. Medium cost.
3. **Compatibility layer** — **Babelfish for Aurora PostgreSQL** accepts TDS protocol + T-SQL. Lowest cost for legacy T-SQL-heavy apps; ties you to Aurora.

Pick the family before you pick the tool.

## Common tools

| Tool | What it does | Notes |
|---|---|---|
| **AWS Schema Conversion Tool (SCT)** | Schema translation with a report of manual items | Free; runs locally. |
| **AWS DMS** | Bulk load + CDC replication | Managed. Serverless or provisioned. |
| **Babelfish** | Aurora PG accepts T-SQL/TDS in-place | Change endpoint from `1433` on SQL Server to Aurora's TDS listener. |
| **Azure Data Migration Service (DMS)** + **SSMA** | Similar to AWS SCT+DMS | SSMA handles schema; DMS handles bulk+CDC. |
| **GCP Database Migration Service** | Continuous SQL Server → Cloud SQL for PostgreSQL | Uses CDC (like DMS). |
| **pgloader** | Streaming loader with type mapping heuristics | Open source; great for one-shot moves and refactors. |
| **ora2pg** (bonus) | For Oracle → PG; the SQL Server sibling is SSMA. |

## The mechanical checklist

### 1. Assessment

- Inventory: databases, sizes, TPS, connections.
- **Feature usage**: SQL Server–specific features that need attention:
  - `IDENTITY`, `sequence` types, `ROWVERSION`, `HIERARCHYID` → mapped types.
  - CLR procs, XML methods, `MERGE` idioms.
  - Full-text indexes (SQL Server → PG `tsvector`).
  - Spatial (`geography`/`geometry`) → PostGIS.
  - CDC / Change Tracking → logical replication.
  - Linked servers → FDWs.
  - SQL Agent jobs → `pg_cron` or a cloud scheduler.
- **Object counts**: tables, procs (procs are the biggest translation cost), triggers, views, DTS/SSIS packages, jobs.
- **Data types**: run SCT/SSMA and read the report end to end.

### 2. Schema conversion

- Run SCT (or SSMA) against a copy of the SQL Server DB.
- Fix items flagged manual: `MERGE` with `OUTPUT`, `CROSS APPLY` (often just becomes `LEFT JOIN LATERAL`), collation choices, identity semantics (SQL Server `IDENTITY(1,1)` → PG `GENERATED ALWAYS AS IDENTITY`).
- Load DDL into a **greenfield PG** and run your CI.

### 3. Data migration

- **Small DB, allow downtime**: `bcp` out from SQL Server → `\copy` into PG. Or `pgloader`. Cutover in one window.
- **Big DB, minimize downtime**: DMS/Azure DMS/Cloud DMS with **initial load + CDC** — snapshot then continuous replication.
- Track row counts and checksums per table. Do a diff on a sample.

### 4. App changes

- **Connection strings**: `jdbc:postgresql://…`, `Npgsql` for .NET, `psycopg[2|3]` for Python, `pg` for Node.
- **T-SQL delta**: see the cheatsheet. Common gotchas:
  - `TOP N` → `LIMIT N`
  - `GETDATE()`/`SYSUTCDATETIME()` → `now() at time zone 'UTC'`
  - `ISNULL(a,b)` → `COALESCE(a,b)`
  - `[bracketed]` identifiers → `"double-quoted"` identifiers (case-sensitive!)
  - `SELECT INTO #tmp` → `CREATE TEMP TABLE ... AS SELECT ...`
  - `EXEC sp_executesql N'...' , @p1, @p2` → prepared/parameterized statements
  - `TRY_CAST` → PL/pgSQL exception blocks
  - `IDENTITY_INSERT ON` → temporarily `OVERRIDING SYSTEM VALUE`
- **Isolation & locking**: no `NOLOCK`; MVCC changes deadlock patterns and lock hierarchies.
- **ORM**: EF Core has a `Npgsql.EntityFrameworkCore.PostgreSQL` provider that translates most LINQ.

### 5. Cutover

Runbook (T-1h → T+1h):

- Freeze DDL on source.
- Verify CDC lag < 5 seconds.
- Announce.
- Stop app writes (feature flag or app off).
- Wait CDC to drain (`replicating` → `caught up`).
- Repoint app connection string; run smoke queries.
- Turn app back on.
- Monitor `pg_stat_activity`, error logs, top statements, wait events.
- Keep source DB read-only for 24–72h in case rollback is needed.

### 6. Rollback

- Only viable in the first hour or so unless you set up bidirectional replication.
- Cheap rollback: undo the connection string flip. Assumes the source has still been receiving writes or you replay the delta.

## Babelfish deep-dive

Aurora PG with Babelfish enabled listens on both 5432 (PG) and 1433 (TDS). Your existing SQL Server app connects to 1433 and speaks T-SQL. Behind the scenes, statements are parsed as T-SQL and translated to PG operations.

**Well-supported**: DML, common DDL, temp tables (`#t`), `TRY/CATCH`, most builtins.
**Partially supported**: cursors, some system stored procedures, `MERGE`, agent-style jobs (use `pg_cron`).
**Not supported**: SQL Agent, SSIS, CLR, Service Broker, Filestream, distributed transactions.

Turn on at Aurora cluster creation via a specific parameter and choose "single-db" or "multi-db" migration mode (affects namespacing). Migrate data with `bcp`/DMS as usual — Babelfish reads the same PG storage; you can also read from a `psql` connection to inspect internal structures.

Great fit when:

- App has thousands of stored procs and moving them is the bottleneck.
- Time-to-first-cutover matters more than long-term optimization.

## Hands-on

You won't fully migrate on Day 26, but do this:

1. Take one small SQL Server table you own (or the `AdventureWorks` sample) and convert its DDL to PG by hand. Then diff against SCT's output. Note the deltas.
2. Rewrite one SQL Server stored proc in PL/pgSQL. Common gotchas:
   - PL/pgSQL uses `DECLARE ... BEGIN ... END; $$ LANGUAGE plpgsql;`
   - `SELECT @a = col FROM t` → `SELECT col INTO a FROM t;`
   - `PRINT` → `RAISE NOTICE`
   - No `RAISERROR`; use `RAISE EXCEPTION USING ERRCODE = 'X';`
3. Sketch a DMS task for one table with CDC.

## Worksheet — the migration runbook draft

Fill each row with two-three sentences.

| Phase | Steps | Owner | Duration |
|---|---|---|---|
| Assess |  |  |  |
| Prepare (schema) |  |  |  |
| Initial load |  |  |  |
| CDC / replicate |  |  |  |
| Test parity |  |  |  |
| Cutover |  |  |  |
| Stabilize |  |  |  |
| Retire source |  |  |  |

## Quick check

1. When would you prefer Babelfish over SCT + DMS?  
   _Answer:_ …
2. Convert to PG: `SELECT TOP 5 * FROM dbo.Users WITH (NOLOCK) WHERE UpdatedAt > DATEADD(day, -1, GETDATE());`  
   _Answer:_ …
3. Name two SQL Server features that have no clean PG mapping.  
   _Answer:_ …
4. A large table has an `IDENTITY(1,1)`. After migration you need to preserve the sequence value. How?  
   _Answer:_ …
5. Post-cutover, `pg_stat_statements` shows huge `LIKE '%something%'` queries. What are three interventions?  
   _Answer:_ …

## References

- AWS Schema Conversion Tool: https://docs.aws.amazon.com/SchemaConversionTool/latest/userguide/CHAP_Welcome.html
- AWS DMS for PostgreSQL: https://docs.aws.amazon.com/dms/latest/userguide/CHAP_Target.PostgreSQL.html
- Babelfish: https://babelfishpg.org/
- Azure DMS: https://learn.microsoft.com/azure/dms/
- GCP Database Migration Service: https://cloud.google.com/database-migration/docs
- pgloader: https://pgloader.readthedocs.io/
