# Day 3 — The `psql` Toolkit (Your SSMS Replacement)

## Objective

Be productive in `psql` in a single sitting: navigation, describing objects, editing queries, scripting, and formatting output. GUI tools are fine, but `psql` is what runs on the bastion, in CI, and inside every managed-service tutorial.

## SQL Server → PostgreSQL bridge

| SQL Server | PostgreSQL |
|---|---|
| SSMS "Object Explorer" | `\l`, `\c`, `\dn`, `\dt`, `\d`, `\df`, `\dv`, `\du` |
| `sqlcmd -i script.sql` | `psql -f script.sql` |
| Results in grid | Default aligned text; `\x` for expanded ("vertical") mode |
| SQLCMD variables `:setvar` | `\set name value` and `:name` |
| `sqlcmd -Q "SELECT ..."` | `psql -c "SELECT ..."` |
| SSMS "Include client statistics" | `\timing on` |
| SSMS Query Editor | `\e` opens the last query in `$EDITOR` |

## Concepts

### The 20 meta-commands you actually use

| Command | Purpose |
|---|---|
| `\?` | Meta-command help. Start here. |
| `\h SELECT` | SQL syntax help. |
| `\l` / `\l+` | List databases. |
| `\c dbname [user]` | Change current database / user. |
| `\dn` | List schemas. |
| `\dt [pattern]` / `\dt+ *.*` | List tables. |
| `\d name` / `\d+ name` | Describe object (columns, indexes, constraints, storage). |
| `\df pattern` | List functions. |
| `\dv` / `\dm` / `\di` | Views / matviews / indexes. |
| `\du` / `\dg` | List roles and group memberships. |
| `\dp` / `\z` | Privileges on tables. |
| `\x` (toggle) | Expanded output — essential for wide rows. |
| `\timing on` | Show wall-clock per query. |
| `\e` | Edit the last query in `$EDITOR`. |
| `\i file.sql` | Run a script. |
| `\o file.txt` | Redirect query output to a file (`\o` alone stops). |
| `\copy tbl FROM 'x.csv' CSV HEADER` | Client-side bulk load (analog of `bcp`). |
| `\watch 5` | Re-run the previous query every 5 seconds. |
| `\set` / `\pset` | Session and formatting variables. |
| `\q` | Quit. |

### Output formatting

```
\pset border 2                -- pretty box
\pset format aligned|unaligned|csv|json|html|latex
\pset null '(null)'
\pset pager off               -- for CI scripts
```

### Scripting

`psql` is fine for batch scripts. It stops on the first error when you pass `-v ON_ERROR_STOP=1`, which you almost always want:

```bash
psql -v ON_ERROR_STOP=1 -f migrate.sql
```

Variable substitution:

```bash
psql -v schema=sales -c "SELECT count(*) FROM :\"schema\".orders;"
```

### The `.psqlrc`

Put this in `~/.psqlrc` — it will save you hours:

```
\set QUIET 1
\pset border 2
\pset null '¤'
\set COMP_KEYWORD_CASE upper
\set HISTFILE ~/.psql_history- :DBNAME
\set HISTSIZE 5000
\set VERBOSITY verbose
\timing on
\x auto
\set PROMPT1 '%[%033[1;32m%]%n@%m:%>%[%033[0m%] %[%033[1;33m%]%~%[%033[0m%]%R%# '
\set PROMPT2 '  … %R> '
\unset QUIET
```

## Hands-on examples

Load `labs/sample-schema.sql` first (day 2), then:

```sql
\c shop
\dn                                     -- schemas
\dt sales.*                             -- tables in sales
\d+ sales.orders                        -- full describe including storage

-- Every column that references orders
SELECT conrelid::regclass AS table_name, conname, pg_get_constraintdef(oid)
FROM pg_constraint
WHERE confrelid = 'sales.orders'::regclass;

-- Show me active queries every 2 seconds
SELECT pid, state, wait_event, now()-query_start AS runtime,
       left(query, 80) AS q
FROM pg_stat_activity WHERE state <> 'idle' ORDER BY runtime DESC NULLS LAST;
\watch 2
```

Bulk-load a CSV client-side:

```bash
\copy sales.orders(customer_id, total, created_at) FROM 'orders.csv' CSV HEADER
```

Server-side (needs SUPERUSER or file_fdw):

```sql
COPY sales.orders FROM '/var/lib/postgresql/orders.csv' CSV HEADER;
```

Save results to a file:

```
\o /tmp/report.csv
\pset format csv
SELECT * FROM sales.top_customers;
\o
```

### One-off remote query from shell

```bash
psql "postgresql://appadmin@localhost:5432/shop?sslmode=disable" \
     -Atc "SELECT count(*) FROM sales.orders;"
# -A = unaligned, -t = tuples only  → clean stdout for scripts
```

## Cloud notes

- All three managed clouds use the same client. Grab the SSL root cert from the vendor, then `sslmode=verify-full sslrootcert=~/.postgresql/root.crt` for the strictest mode.
- **RDS**: use IAM auth — `psql "host=… user=… dbname=…"` with `PGPASSWORD=$(aws rds generate-db-auth-token …)`.
- **Cloud SQL**: prefer the **Auth Proxy** — it turns `-h 127.0.0.1 -p 5432` into an authenticated tunnel; your `psql` command is unchanged.
- **Azure Flexible Server**: usernames are `user` (not `user@server`) since Flexible Server; the older `user@server` style was Single Server (retired).

## Worksheet

1. Add three items to your `~/.psqlrc` that you'd want in a production bastion.  
   _Answer:_ …
2. Write a one-liner `psql` command that returns the total row count of `sales.orders` with no headers, no formatting, and exits non-zero if the query fails.  
   _Answer:_ …
3. Use `\watch` to build a "live" query showing the 5 longest-running queries. Paste the query.  
   _Answer:_ …
4. Convert this SSMS habit — `Ctrl+R` to hide the results pane — into an equivalent `psql` workflow. What are your two most-used `\pset` settings?  
   _Answer:_ …
5. `\copy` vs `COPY`: when do you use which? Which one is legal on RDS?  
   _Answer:_ …

## References

- `psql` reference: https://www.postgresql.org/docs/current/app-psql.html
- `.psqlrc` recipes: https://wiki.postgresql.org/wiki/Psqlrc
