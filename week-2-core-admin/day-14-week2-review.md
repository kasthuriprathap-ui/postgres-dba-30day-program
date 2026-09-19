# Day 14 — Week 2 Review

## Objective

Prove to yourself you can operate a PostgreSQL cluster end-to-end at the engine level. If you can complete the drill below without notes, Week 3 (managed clouds) will be a comfortable overlay.

## The Sunday drill

Set aside 60–90 minutes. Do it on your local Docker cluster with `shop` loaded.

### 1. Backup / restore (15 min)

- [ ] Take a `pg_dump -Fc` of `shop`.
- [ ] Create a fresh DB `shop_test` and `pg_restore` into it with `-j 4`.
- [ ] Confirm row counts on `sales.customers` and `sales.orders` match.
- [ ] Bonus: `pg_basebackup` the whole cluster into `/tmp/base`.

### 2. PITR simulation (15 min)

- [ ] With WAL archiving turned on (day 9), note `SELECT now();`, drop `sales.orders`.
- [ ] Stop the cluster, restore the base backup into a temp directory.
- [ ] Set `restore_command`, `recovery_target_time`, `recovery_target_action = 'promote'`, drop `recovery.signal`.
- [ ] Start it up, `SELECT count(*) FROM sales.orders;` — you win when the row count matches pre-drop.

### 3. Vacuum & bloat (10 min)

- [ ] Run the bloat query from day 10.
- [ ] Pick the most bloated table, `VACUUM (VERBOSE, ANALYZE)` it, and note the log output.
- [ ] Override autovacuum parameters on that table with a scale factor of 0.02.

### 4. Index & plan (15 min)

- [ ] Write a query on `sales.orders` you *know* will do a `Seq Scan`.
- [ ] Add an index with `CONCURRENTLY` that flips it to `Index Only Scan`.
- [ ] `EXPLAIN (ANALYZE, BUFFERS)` before and after — screenshot both.
- [ ] Set `work_mem` twice as big and rerun a `GROUP BY` — did the sort go from disk to memory?

### 5. Parameters & pooling (10 min)

- [ ] Show your current top 15 parameter settings and mark any you'd change for production.
- [ ] Given `max_connections = 300` and `work_mem = 32 MB`, estimate the worst-case memory.
- [ ] Draw the request path from an app instance → PgBouncer → Postgres for `pool_mode = transaction`.

## Consolidated worksheet

Compare your answers against a peer's; both can be right.

1. Write the DR runbook (draft, five bullets) for restoring a single dropped table using your Week 2 skills.  
   _Answer:_ …

2. Which two parameters would you tighten first in a fresh production cluster on RDS?  
   _Answer:_ …

3. A query returns in 15s. `EXPLAIN ANALYZE` shows an external sort. Give three interventions in order of effort.  
   _Answer:_ …

4. You add `CREATE INDEX CONCURRENTLY` to a migration. What one safeguard do you also add to your deploy tool?  
   _Answer:_ …

5. `pg_stat_archiver.last_failed_time > last_archived_time` for the last hour. Root-cause the three most likely reasons.  
   _Answer:_ …

## Answer key

<details>
<summary>Show answers</summary>

1. Confirm PITR window covers the incident time, provision a target host, restore base backup, set `recovery_target_time`, promote, extract the table with `pg_dump -t`, import into prod, communicate.
2. `statement_timeout` and `idle_in_transaction_session_timeout` — the two cheapest guardrails.
3. Bump `work_mem` for the session; add or fix an index that removes the sort; rewrite the query (aggregate pushdown, `DISTINCT ON`, etc.).
4. Split it into its own migration step outside a transaction (or a wrapper that detects invalid indexes and retries).
5. Archive destination unreachable/full; permissions changed on the destination; the archive command has a typo/uses a wrong variable expansion.
</details>

## Personal checklist for the rest of the course

Print this. Tick items as you can do them from muscle memory.

- [ ] I can `pg_dump` and `pg_restore` in three formats.
- [ ] I can enable and verify WAL archiving.
- [ ] I can perform a PITR to a chosen timestamp.
- [ ] I can spot bloat and override per-table autovacuum.
- [ ] I can identify unused indexes and add covering ones online.
- [ ] I can read a plan and identify the top 3 problems in seconds.
- [ ] I know the 15 parameters that matter and defensible starting values.
- [ ] I know when to introduce PgBouncer.

On to Week 3: same engine, now on someone else's servers.
