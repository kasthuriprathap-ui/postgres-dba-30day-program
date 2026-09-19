# Day 2 — Installation, `PGDATA`, and Connectivity

## Objective

Stand up a local PostgreSQL 16 cluster, connect to it, load the sample schema, and understand `pg_hba.conf`.

## SQL Server → PostgreSQL bridge

| SQL Server | PostgreSQL |
|---|---|
| Setup wizard, `SQL Server Configuration Manager` | `initdb`, `pg_ctl`, systemd unit, or container |
| `sqlservr.exe` as a Windows service | `postgres` daemon under systemd/launchd or container |
| SQL Server Authentication vs Windows Auth | `md5` / `scram-sha-256` / `peer` / `ident` / `cert` / `gss` — controlled by `pg_hba.conf` |
| SSMS "Connect" dialog | Connection strings: `host=… port=… dbname=… user=… password=… sslmode=…` |
| `HKLM\SOFTWARE\Microsoft\MSSQLServer\...` | `postgresql.conf` + `pg_hba.conf` + `pg_ident.conf` in `PGDATA` |

## Concepts

### The `PGDATA` directory

`PGDATA` is one folder that contains everything the cluster needs: config, data files, WAL, control file. If you tar it (while the server is down) and untar it elsewhere, you have a byte-identical clone.

Key files:

- `postgresql.conf` — all engine parameters.
- `postgresql.auto.conf` — written by `ALTER SYSTEM SET ...`; overrides `postgresql.conf`.
- `pg_hba.conf` — "Host-Based Authentication" — which client can connect to which DB as which user with which method.
- `pg_ident.conf` — OS-user → PG-role mapping for `peer`/`ident` methods.
- `pg_wal/` — WAL segments (16 MB each by default).
- `base/` — table and index files, one subdirectory per database (named by OID).
- `PG_VERSION`, `postmaster.pid`, `global/pg_control` — cluster metadata.

### `pg_hba.conf` — the firewall

Every connection is evaluated top-to-bottom. First match wins.

```
# TYPE   DATABASE   USER          ADDRESS          METHOD
local    all        all                            peer                      # unix socket, OS user must match role name
host     all        all           127.0.0.1/32     scram-sha-256             # localhost TCP
host     all        all           10.0.0.0/8       scram-sha-256             # VPC
hostssl  appdb      app_user      0.0.0.0/0        scram-sha-256             # public but SSL only
host     replication replicator   10.0.0.0/8       scram-sha-256             # standbys
```

Prefer `scram-sha-256` (PG 10+). `md5` is legacy. `trust` is a footgun.

Managed services hide `pg_hba.conf` behind allowlists / firewall rules / VPC settings. Same concept, different knob.

### Connection strings

Two equivalent forms:

```
psql "host=db.example.com port=5432 dbname=appdb user=app_user sslmode=require"
psql "postgresql://app_user@db.example.com:5432/appdb?sslmode=require"
```

Environment variables act as defaults: `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD`, `PGSSLMODE`, `PGSERVICE`, `PGAPPNAME`. A `~/.pg_service.conf` gives named connection profiles.

`.pgpass` (mode 0600):

```
# hostname:port:database:username:password
db.example.com:5432:*:app_user:s3cret
```

## Hands-on examples

### Option A — local Docker (recommended)

```bash
mkdir -p ~/pgdba-lab && cd ~/pgdba-lab
cp <workspace>/postgres-dba-30day-program/labs/docker-compose-local-postgres.yml docker-compose.yml
docker compose up -d

# wait ~5s, then:
docker exec -it pgdba psql -U postgres
```

Then load the sample schema (see `labs/sample-schema.sql`):

```bash
docker exec -i pgdba psql -U postgres -d postgres < <workspace>/postgres-dba-30day-program/labs/sample-schema.sql
```

### Option B — native install

macOS: `brew install postgresql@16 && brew services start postgresql@16`
Ubuntu: `sudo apt install postgresql-16` (auto-starts under systemd; `PGDATA=/var/lib/postgresql/16/main`).

### First tour

```bash
psql -U postgres

-- Show where PG lives
SHOW data_directory;
SHOW hba_file;
SHOW config_file;

-- Create your DBA user and a workload DB
CREATE ROLE appadmin LOGIN PASSWORD 'ChangeMe!' CREATEDB CREATEROLE;
CREATE DATABASE shop OWNER appadmin;

\c shop appadmin
CREATE SCHEMA sales AUTHORIZATION appadmin;
```

Reload config after editing files (no restart needed for most parameters):

```sql
SELECT pg_reload_conf();
-- Which parameters need a restart?
SELECT name, context FROM pg_settings WHERE context = 'postmaster' LIMIT 20;
```

## Cloud notes

- **AWS RDS**: connectivity = security group + subnet group + parameter group. You get a DNS endpoint; SSL is on by default. Use IAM DB authentication or SCRAM.
- **Azure Flexible Server**: choose "Public access" (with firewall rules) or "Private access" (VNet-integrated). SSL required; download the DigiCert root if your client complains.
- **GCP Cloud SQL**: authorized networks + optional Private Service Connect. The **Cloud SQL Auth Proxy** is the recommended access pattern — it handles SSL and IAM.

## Worksheet

1. Write a `pg_hba.conf` line that: forces SSL, uses SCRAM, allows the role `analytics_ro` from CIDR `10.20.0.0/16`, only to the `warehouse` DB.  
   _Answer:_ …

2. What's the difference between `local`, `host`, and `hostssl` line types?  
   _Answer:_ …

3. Which of these parameters require a **restart** vs a **reload**?  
   `shared_buffers`, `work_mem`, `max_connections`, `log_min_duration_statement`, `wal_level`.  
   _Answer:_ …

4. On the sample DB, create a role `readonly` that can connect to `shop` and `SELECT` from any current or future table in schema `sales`.  
   _Answer:_ … (foreshadow of day 5)

5. Sketch how you'd connect from your laptop to a private-VNet Azure Flexible Server. Which knobs must line up?  
   _Answer:_ …

## References

- Client Authentication (`pg_hba.conf`): https://www.postgresql.org/docs/current/auth-pg-hba-conf.html
- `libpq` connection strings: https://www.postgresql.org/docs/current/libpq-connect.html
- SCRAM: https://www.postgresql.org/docs/current/sasl-authentication.html
