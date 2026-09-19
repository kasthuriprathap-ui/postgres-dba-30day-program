# Day 8 — Backup and Restore

## Objective

Perform, verify, and restore three kinds of backups: logical (`pg_dump`), physical (`pg_basebackup`), and (preview of day 9) WAL-based PITR. Know which to reach for and why.

## SQL Server → PostgreSQL bridge

| SQL Server | PostgreSQL | Notes |
|---|---|---|
| `BACKUP DATABASE ... TO DISK` FULL | `pg_basebackup` (whole cluster) or `pg_dump` (one DB) | PG has no "full DB" backup in the FULL/DIFF sense; you either take a filesystem-consistent physical copy or a logical dump. |
| `BACKUP DATABASE ... DIFFERENTIAL` | None natively. Incremental via file-level tools: `pgBackRest`, `barman`, `WAL-G`, or PG 17+ `pg_basebackup --incremental`. | |
| `BACKUP LOG` | WAL archiving (`archive_command` / `archive_library`) | Day 9. |
| `RESTORE DATABASE ... WITH RECOVERY / NORECOVERY / STANDBY` | Physical restore uses filesystem + WAL replay driven by `recovery.signal`/`standby.signal` | Day 9. |
| `RESTORE ... STOPAT` | `recovery_target_time` in `postgresql.conf` | Day 9. |
| `sqlpackage` / .bacpac | `pg_dump --format=directory` (parallel) or `-Fc` custom | |
| VDI/snap backup | Storage snapshot with `pg_backup_start()`/`pg_backup_stop()` or `pg_basebackup` | On managed PG this is what the cloud does under the hood. |

## Concepts

### Logical vs physical

**Logical (`pg_dump`)** produces SQL/`COPY` statements that describe the objects and data. It:
- Works between versions and across architectures.
- Is per-database (one DB at a time, not the whole cluster).
- Is slower for large databases; single-transaction consistency snapshot.
- Is the only option to move a subset (one schema, one table).
- Has a parallel directory format for large DBs.

**Physical (`pg_basebackup`)** copies the raw data files. It:
- Is fast and produces an exact byte-image at a WAL LSN.
- Is per-cluster (all databases).
- Requires the same major version and same architecture on restore.
- Is the foundation for streaming replicas and PITR.

**Rule of thumb:**
- Use `pg_dump` for schema moves, per-DB refreshes, and cross-version upgrades.
- Use `pg_basebackup` + WAL archiving for DR of the whole cluster.
- Use a proven tool (**pgBackRest**, **WAL-G**, **barman**) for production PITR of anything nontrivial.

### `pg_dump` formats

| `-F` | Best for |
|---|---|
| `plain` (default) | Small DBs, human-readable `.sql`, restore with `psql` |
| `custom` (`-Fc`) | Compressed single file, restore with `pg_restore`, selective restore |
| `directory` (`-Fd`) | Parallel dump/restore (`-j N`), large DBs |
| `tar` | Rare; use directory instead |

`pg_restore` is the tool for `-Fc` and `-Fd`. It supports `--jobs`, `--section=pre-data|data|post-data`, and per-object filtering (`-t`, `-n`).

### Consistency and snapshots

`pg_dump` starts a `REPEATABLE READ` transaction and reads everything through one snapshot. Parallel dumps (`-Fd -j N`) use synchronized snapshots so all workers see the same instant.

`pg_basebackup` calls `pg_backup_start()` / `pg_backup_stop()` internally and captures the WAL range needed to make the copy self-consistent.

## Hands-on examples

Assume the sample DB `shop` from Week 1.

### Logical: full DB, plain SQL

```bash
pg_dump -U postgres -h localhost -d shop -Fp -f shop.sql
# restore into a new DB
createdb -U postgres shop_restore
psql -U postgres -d shop_restore -v ON_ERROR_STOP=1 -f shop.sql
```

### Logical: custom format + parallel restore

```bash
pg_dump -U postgres -d shop -Fd -j 4 -f /tmp/shop_dump
pg_restore -U postgres -d shop_new -j 4 /tmp/shop_dump
```

### Logical: only one schema, only one table

```bash
pg_dump -d shop -n sales -Fc -f sales.dump
pg_dump -d shop -t 'sales.orders' -Fp -f orders.sql
```

### Logical: schema-only, data-only

```bash
pg_dump -d shop --schema-only -f schema.sql
pg_dump -d shop --data-only   -f data.sql
```

### Physical: whole cluster

```bash
# From an operator host that can reach the cluster on the replication protocol
pg_basebackup -h db-primary -U replicator -D /var/lib/pgbackup/base_$(date +%F) \
              -Ft -z -X stream -c fast -P

# Or, uncompressed, plain layout suitable for a standby:
pg_basebackup -h db-primary -U replicator -D /var/lib/pgstandby -Fp -X stream -R
# -R writes standby.signal + primary_conninfo — instant replica
```

### Verify a dump

Always test restore on a scratch host. A backup you have not restored is a wish.

```bash
pg_restore --list /tmp/shop.dump | head          # object catalog
pg_restore --schema-only -d fresh /tmp/shop.dump # DDL only
```

### Automated logical dumps with retention (cron-safe)

```bash
#!/usr/bin/env bash
set -euo pipefail
DEST=/var/backups/pg
DB=shop
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$DEST"
pg_dump -Fc -d "$DB" -f "$DEST/${DB}_${STAMP}.dump"
find "$DEST" -name "${DB}_*.dump" -mtime +14 -delete
```

## Cloud notes

- **AWS RDS/Aurora**: automated snapshots (physical) run daily; PITR replays WAL up to your window (up to 35 days). You can also take manual snapshots. `pg_dump` still works and is your friend for cross-region/cross-account logical moves. Use IAM auth or Secrets Manager for the dump host's credentials.
- **Azure Flexible Server**: automated backups (LRS/ZRS/GRS) with PITR 1–35 days. `pg_dump` also works.
- **Cloud SQL**: automated backups + 7-day PITR by default (extendable). Export to Cloud Storage runs `pg_dump` under the hood.
- **AlloyDB**: continuous backup + PITR up to 35 days.

You still take **your own logical dumps** on a schedule you own. Cloud PITR is fantastic but "just in case" out-of-region dumps in your own bucket + your own encryption key survive account/region incidents.

## Worksheet

1. Choose the right tool for each situation:
   a. Copy schema `reporting` from prod to a dev cluster.  
   b. Rebuild a 400 GB cluster on a new host in a different region, RPO ~5 min.  
   c. Recover one table dropped 40 minutes ago.  
   d. Move a database across major versions (14 → 16).  

2. Write the `pg_dump` command to dump only DDL (no data) of DB `shop`, schema `sales`, in a form that can be restored with `psql`.  
   _Answer:_ …

3. Design a `cron` for daily logical dumps of `shop` at 03:00 UTC, keeping 14 days on disk and shipping the newest to S3.  
   _Answer:_ …

4. What's the risk of running `pg_dump` on a very active production database, and how does `pg_basebackup` sidestep it?  
   _Answer:_ …

5. Bonus: your RDS restore-to-a-point failed with "backup version incompatible." Two plausible causes?  
   _Answer:_ …

## References

- `pg_dump`: https://www.postgresql.org/docs/current/app-pgdump.html
- `pg_restore`: https://www.postgresql.org/docs/current/app-pgrestore.html
- `pg_basebackup`: https://www.postgresql.org/docs/current/app-pgbasebackup.html
- pgBackRest: https://pgbackrest.org/
