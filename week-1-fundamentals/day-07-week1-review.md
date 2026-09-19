# Day 7 — Week 1 Review & Self-Assessment

## Objective

Consolidate everything you learned this week and produce a personal cheat sheet you can keep at your desk.

## What you should now be able to do

- [ ] Draw the cluster → database → schema → object hierarchy from memory.
- [ ] Explain the process-per-connection model and why it demands a pooler at scale.
- [ ] Read and write a `pg_hba.conf` line.
- [ ] Live-drive `psql` — describe an object, run a script, save output to CSV, and use `\watch`.
- [ ] Choose PostgreSQL types for any SQL Server table.
- [ ] Design a four-role permission model and apply `ALTER DEFAULT PRIVILEGES` correctly.
- [ ] Explain MVCC and predict the runtime effect of a long transaction.

## Self-assessment (30 minutes)

Do these in order without notes. Compare against `../SQL_SERVER_TO_POSTGRES_CHEATSHEET.md` after.

### Section A — short answer

1. What's the PostgreSQL equivalent of a SQL Server `sysadmin` login on RDS? Why isn't it exactly `SUPERUSER`?
2. Difference between `template0` and `template1`?
3. `search_path = "$user", public` — what does `"$user"` resolve to and why is that useful?
4. Name three parameters that require a **restart** to change.
5. When does `\copy` differ from `COPY`? Which one runs on RDS?

### Section B — apply

6. Write the SQL to:
   - Create a role `finance_ro` that can `SELECT` from any current or future table in schema `finance`.
   - The migrations run as role `deploy`.
7. Write the query that lists sessions currently blocked and which pid is blocking them.
8. Convert this T-SQL to PG:
   ```sql
   IF NOT EXISTS (SELECT 1 FROM dbo.Users WHERE Email = @e)
     INSERT INTO dbo.Users(Email, CreatedAtUTC) VALUES (@e, SYSUTCDATETIME());
   ```
9. Given a table with `attributes jsonb`, add the right index and write a query for `attributes @> '{"tier":"gold"}'`.
10. In psql, produce a live-updating dashboard of the top 5 longest-running non-idle queries. Which meta-command do you use?

### Section C — troubleshoot

11. A dev complains: `permission denied for schema sales`. They already have `SELECT` on the tables. What's the missing grant?
12. A monitoring dashboard shows table bloat growing every hour. The autovacuum log looks healthy. What's the most likely single cause?
13. Two queries deadlocked with `SQLSTATE 40P01`. The app retries the whole transaction. Is that safe? Any better options?

## Answer key (peek only after you've tried)

<details>
<summary>Show answers</summary>

A1. `rds_superuser`. It has most privileges but cannot touch AWS-owned objects or file system, which real `SUPERUSER` could.
A2. `template0` is pristine and never modified; use it to build a clean DB with a specific encoding/locale. `template1` is the default template — anything you add there appears in every `CREATE DATABASE`.
A3. `"$user"` resolves to the role name of the connecting session — so if a role has a same-named schema, it becomes their working namespace. Handy for multi-tenant.
A4. `shared_buffers`, `max_connections`, `wal_level`, `wal_buffers`, `port`, `listen_addresses`. (Any three.)
A5. `\copy` is client-side (runs in `psql`), reads the file on your machine. `COPY` is server-side, reads the file on the server. On RDS only `\copy` (and `aws_s3.table_import_from_s3`) work — no server filesystem for you.

B6.
```sql
CREATE ROLE finance_ro NOLOGIN;
GRANT CONNECT ON DATABASE shop TO finance_ro;
GRANT USAGE ON SCHEMA finance TO finance_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA finance TO finance_ro;
ALTER DEFAULT PRIVILEGES FOR ROLE deploy IN SCHEMA finance
  GRANT SELECT ON TABLES TO finance_ro;
```

B7.
```sql
SELECT blocked.pid AS blocked_pid,
       blocked.query AS blocked_query,
       blocking.pid AS blocking_pid,
       blocking.query AS blocking_query
FROM pg_stat_activity blocked
JOIN LATERAL unnest(pg_blocking_pids(blocked.pid)) AS b(pid) ON true
JOIN pg_stat_activity blocking ON blocking.pid = b.pid
WHERE cardinality(pg_blocking_pids(blocked.pid)) > 0;
```

B8.
```sql
INSERT INTO users(email, created_at)
VALUES (:'e', now())
ON CONFLICT (email) DO NOTHING;
```

B9.
```sql
CREATE INDEX customers_attributes_gin ON customers USING gin (attributes jsonb_path_ops);
SELECT * FROM customers WHERE attributes @> '{"tier":"gold"}';
```

B10. `\watch 2` after the base query.

C11. `USAGE` on the schema.
C12. A long-running transaction (`idle in transaction` or a slow analytics query) is pinning the xmin horizon.
C13. Yes, but only if the app's transaction is idempotent-on-retry. Better: keep transactions short, and prefer `INSERT ... ON CONFLICT` over separate `SELECT`+`INSERT`.
</details>

## Personal cheat sheet template

Fill this in and keep it beside your keyboard for weeks 2–4. Move on when you can fill every row.

| # | Concept | Your one-line summary | Command you always forget |
|---|---|---|---|
| 1 | Cluster vs database vs schema | | |
| 2 | pg_hba.conf top-to-bottom, first match | | |
| 3 | psql `\d+` | | |
| 4 | `timestamptz` default | | |
| 5 | Default privileges for future objects | | |
| 6 | MVCC + long-txn = bloat | | |
| 7 | `SELECT pg_reload_conf()` vs restart | | |
| 8 | `SET lock_timeout` before DDL | | |
| 9 | `CREATE INDEX CONCURRENTLY` cannot be in a txn | | |
| 10 | `pg_stat_activity` for live sessions | | |

Now on to Week 2 — core administration.
