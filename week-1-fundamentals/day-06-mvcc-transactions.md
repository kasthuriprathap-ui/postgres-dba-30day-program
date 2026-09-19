# Day 6 — MVCC, Transactions, and Locking

## Objective

Explain, with confidence, why readers never block writers in PostgreSQL, why long-running transactions are the single most operationally toxic thing you can do to a PG database, and how the four isolation levels behave.

## SQL Server → PostgreSQL bridge

| SQL Server | PostgreSQL |
|---|---|
| Row versions in `tempdb` (RCSI/SI) | Row versions **in the table itself** (each `UPDATE` creates a new tuple) |
| `WITH (NOLOCK)` / dirty reads | Not honored — lowest level is `READ COMMITTED` |
| `SERIALIZABLE` = 2PL | `SERIALIZABLE` = SSI (Serializable Snapshot Isolation) — optimistic |
| Deadlock graph → victim aborts | Same mechanic |
| `sys.dm_tran_locks` | `pg_locks` |
| Long-running txn = tempdb growth | Long-running txn = **bloat** in tables + inability to freeze tuples + WAL retention |
| `sp_lock`, `sp_who2` | `pg_stat_activity` + `pg_locks` + `pg_blocking_pids()` |

## Concepts

### MVCC in one paragraph

Every row stores two hidden columns: `xmin` (transaction that inserted it) and `xmax` (transaction that deleted or superseded it). Every transaction has a snapshot — a set of "which xids are visible to me." A `SELECT` reads all versions in the pages it visits but returns only those whose `xmin`/`xmax` are visible to its snapshot. Writers create new row versions and mark the old ones with their `xmax`. This means:

- Readers never take row locks. They never block writers, and writers never block them.
- `UPDATE` writes a whole new tuple. The old one becomes a dead tuple and must be reclaimed by **VACUUM** (day 10).
- Long transactions hold back the "oldest visible snapshot horizon" (`xmin` horizon) and prevent vacuum from removing dead tuples anywhere in the cluster.

### Transactions and DDL

Almost all DDL is transactional in PG. You can:

```sql
BEGIN;
  CREATE TABLE t (id int);
  ALTER TABLE t ADD COLUMN name text;
  INSERT INTO t VALUES (1, 'a');
ROLLBACK;   -- t never existed.
```

Exceptions (cannot run inside a transaction block): `CREATE INDEX CONCURRENTLY`, `REINDEX CONCURRENTLY`, `VACUUM`, `CREATE DATABASE`, `ALTER SYSTEM`.

### Isolation levels

| Level | What it prevents | What it doesn't | PG behavior |
|---|---|---|---|
| `READ UNCOMMITTED` | (nothing) | dirty reads | Treated as `READ COMMITTED` in PG. |
| `READ COMMITTED` (default) | dirty reads | non-repeatable reads, phantoms | Each statement gets a fresh snapshot. |
| `REPEATABLE READ` | non-repeatable reads, phantoms* | some anomalies | Snapshot at first statement of the txn. `*` — PG's implementation prevents phantoms too. Serialization failures possible: `40001`. |
| `SERIALIZABLE` | all anomalies | | Snapshot + predicate locks (SSI). Can abort with `40001` — retry in app. |

Set at session or per transaction:

```sql
SET default_transaction_isolation = 'repeatable read';
BEGIN ISOLATION LEVEL SERIALIZABLE;
```

### Locks you should know

- **ACCESS SHARE / ROW SHARE** — SELECT / SELECT FOR SHARE
- **ROW EXCLUSIVE** — INSERT/UPDATE/DELETE
- **SHARE / SHARE ROW EXCLUSIVE** — used by CREATE INDEX (non-concurrent)
- **EXCLUSIVE** — REFRESH MATERIALIZED VIEW CONCURRENTLY
- **ACCESS EXCLUSIVE** — DROP, TRUNCATE, most `ALTER TABLE`, VACUUM FULL, non-concurrent CREATE INDEX

Rule: any DDL that takes `ACCESS EXCLUSIVE` **also blocks selects**. Even a fast one — the problem is not the DDL itself, it's the wait behind a slow `SELECT` that then blocks the world.

Use `lock_timeout` in migrations:

```sql
SET lock_timeout = '3s';
ALTER TABLE big_table ADD COLUMN new_col int;   -- fail fast if blocked
```

### `idle in transaction`

If a session runs `BEGIN;` and then goes idle, its snapshot pins the xmin horizon. Vacuum can't reclaim newer dead tuples until this transaction ends. Two safeguards:

```sql
-- Kill idle-in-transaction sessions after 5 min
ALTER SYSTEM SET idle_in_transaction_session_timeout = '5min';
-- Kill any session waiting on a lock more than 30s
ALTER SYSTEM SET lock_timeout = '30s';
-- Kill any statement over 5 min
ALTER SYSTEM SET statement_timeout = '5min';
SELECT pg_reload_conf();
```

## Hands-on examples

Open two `psql` sessions to `shop`.

### Demo 1 — readers never block writers

```sql
-- Session A
BEGIN;
UPDATE sales.customers SET full_name = 'Alicia' WHERE id = 1;
-- do not commit

-- Session B (parallel)
SELECT id, full_name FROM sales.customers WHERE id = 1;   -- returns Alice, immediately
```

Session B sees the pre-update version because Session A hasn't committed.

### Demo 2 — writers block writers on the same row

```sql
-- Session A (still open, still uncommitted)
-- Session B:
UPDATE sales.customers SET full_name = 'A. Smith' WHERE id = 1;   -- hangs

-- In Session C:
SELECT pid, wait_event_type, wait_event, query FROM pg_stat_activity
WHERE state = 'active';

SELECT pg_blocking_pids(<B_pid>);
```

Commit A → B unblocks. Roll back A → B applies to original row.

### Demo 3 — SSI serialization failure

```sql
CREATE TABLE t (id int primary key, v int);
INSERT INTO t VALUES (1,0),(2,0);

-- Session A
BEGIN ISOLATION LEVEL SERIALIZABLE;
UPDATE t SET v = (SELECT sum(v) FROM t WHERE id <> 1) WHERE id = 1;

-- Session B
BEGIN ISOLATION LEVEL SERIALIZABLE;
UPDATE t SET v = (SELECT sum(v) FROM t WHERE id <> 2) WHERE id = 2;

-- Commit A → OK.
-- Commit B → ERROR: could not serialize access due to read/write dependencies
```

Your app must retry on `SQLSTATE '40001'`.

### Demo 4 — bloat from a long transaction

```sql
-- Session A: leave a snapshot pinned
BEGIN;
SELECT * FROM sales.customers LIMIT 1;
-- do not commit

-- Session B:
UPDATE sales.customers SET full_name = full_name || '.' ; -- rewrite every row
-- Repeat a few times.
VACUUM (VERBOSE) sales.customers;
-- observe: "removable versions: 0" because A still holds a snapshot
```

## Cloud notes

Managed services enforce good hygiene with parameters like `idle_in_transaction_session_timeout` and expose deadlock alerting through their monitoring layer (day 25). The dynamics of MVCC are identical everywhere.

## Worksheet

1. Explain, in three sentences, why a "small" long-lived transaction can grow a 100 GB table into a 400 GB table.  
   _Answer:_ …

2. Given the four isolation levels, which one would you choose for:  
   a. An OLTP transaction that debits an account and credits another → …  
   b. A nightly reporting query → …  
   c. A daily aggregation that both reads and writes → …  

3. Write the SQL to find the top 3 blockers in `pg_stat_activity` right now (sessions blocking the most others).  
   _Answer:_ …

4. Add these three timeouts to your reference `postgresql.conf` (or a parameter group). What values would you pick for a typical OLTP workload?  
   `statement_timeout`, `idle_in_transaction_session_timeout`, `lock_timeout`.  
   _Answer:_ …

5. `SELECT FOR UPDATE` in SQL Server vs PostgreSQL — same? different? Explain to a developer.  
   _Answer:_ …

## References

- Concurrency Control: https://www.postgresql.org/docs/current/mvcc.html
- Explicit Locking: https://www.postgresql.org/docs/current/explicit-locking.html
- SSI paper (accessible): https://drkp.net/papers/ssi-vldb12.pdf
