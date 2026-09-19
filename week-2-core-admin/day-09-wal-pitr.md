# Day 9 — WAL, Archiving, and Point-in-Time Recovery

## Objective

Configure WAL archiving on a self-hosted cluster, take a base backup, simulate a disaster ("someone dropped the orders table"), and restore to a specific timestamp.

## SQL Server → PostgreSQL bridge

| SQL Server | PostgreSQL |
|---|---|
| Transaction log | WAL |
| Log backup (`BACKUP LOG`) | Continuous archiving of WAL files |
| Log shipping | `archive_command` → shared storage → `restore_command` on standby |
| PITR: `RESTORE ... STOPAT` | Restore a base backup, set `recovery_target_time`, start server |
| VLFs | WAL segments (default 16 MB) |
| Log truncation | WAL file recycling after replication + archiving |
| `sys.dm_db_log_info` | `pg_stat_archiver`, `pg_ls_waldir()`, `pg_current_wal_lsn()` |

## Concepts

### The WAL lifecycle

1. A backend writes changes to **WAL buffers** in memory.
2. On `COMMIT` (or when the WAL writer decides), those buffers are flushed to `pg_wal/*` and `fsync`'d.
3. A **checkpoint** flushes the corresponding dirty data pages so WAL prior to the checkpoint is no longer needed for crash recovery.
4. If `archive_mode = on`, the `archiver` process copies each completed WAL segment to your **archive** via `archive_command` (or `archive_library` in PG 15+).
5. WAL files can be removed only after they are archived **and** no replica still needs them (streaming) **and** no replication slot pins them.

### `wal_level`

| Value | Enables |
|---|---|
| `minimal` | Crash recovery only. No PITR, no streaming replication. |
| `replica` (default) | PITR + physical streaming replication. |
| `logical` | Everything above + logical decoding / logical replication. |

Managed PG runs `replica` or `logical`. You cannot go below `replica` and still get PITR.

### Archive command patterns

```
# Simple filesystem archive (mount an NFS share)
archive_command = 'test ! -f /mnt/wal-archive/%f && cp %p /mnt/wal-archive/%f'

# Ship to S3 with WAL-G (recommended in production)
archive_command = 'wal-g wal-push %p'

# Ship to GCS
archive_command = 'wal-g wal-push %p'  # WAL-G supports GCS too

# Ship to Azure blob
archive_command = 'wal-g wal-push %p'
```

Never point two clusters at the same archive location. That corrupts the timeline.

### Timelines

Each PITR "branches" the cluster into a new **timeline**. WAL is namespaced by timeline id (`00000001`, `00000002`, ...). You can restore to a specific timeline in the future too: after PITR, subsequent WAL is written on the new timeline.

### The recovery flow (PG 12+)

To restore:

1. Restore the base backup to `PGDATA`.
2. Create `recovery.signal` file (empty file in `PGDATA`).
3. Set the following in `postgresql.conf` (or `postgresql.auto.conf`):

```
restore_command = 'cp /mnt/wal-archive/%f %p'   # or wal-g wal-fetch %f %p
recovery_target_time = '2026-09-16 14:30:00+00'
recovery_target_action = 'promote'              # 'pause' if you want to double-check
```

4. Start the server. It replays WAL up to the target, then promotes.

For a **standby** (not PITR), you create `standby.signal` instead and set `primary_conninfo` — the server stays in recovery indefinitely, applying streaming WAL.

## Hands-on examples

Do this against your local Docker cluster.

### Turn on archiving

```bash
docker exec -it pgdba bash -lc '
mkdir -p /var/lib/postgresql/wal-archive && chown postgres /var/lib/postgresql/wal-archive
'
```

Edit `postgresql.conf` (in the container) — or use `ALTER SYSTEM`:

```sql
ALTER SYSTEM SET wal_level = 'replica';
ALTER SYSTEM SET archive_mode = 'on';
ALTER SYSTEM SET archive_command = $$test ! -f /var/lib/postgresql/wal-archive/%f && cp %p /var/lib/postgresql/wal-archive/%f$$;
```

Restart the container to pick up `archive_mode`:

```bash
docker restart pgdba
```

Verify:

```sql
SELECT name, setting FROM pg_settings WHERE name IN
  ('wal_level','archive_mode','archive_command');

SELECT * FROM pg_stat_archiver;
```

### Base backup

```bash
docker exec -u postgres -it pgdba \
  pg_basebackup -D /var/lib/postgresql/base_$(date +%F) -Fp -X stream -P -c fast
```

### Cause "damage" and note the time

```sql
SELECT now();                             -- note this timestamp
-- pretend disaster:
DROP TABLE sales.orders;
```

### Restore to a point just before the drop

Stop the primary. Move base backup to a new directory. Set `restore_command`, `recovery_target_time` (using the timestamp you noted above), and drop a `recovery.signal`. Start the server. Verify `sales.orders` is back:

```sql
SELECT count(*) FROM sales.orders;
```

Reality check: the point of this exercise is not to memorize the exact steps — those live in your runbook — but to internalize that the recipe is *base backup + archived WAL + a target time + a signal file*.

### Monitoring the pipeline

```sql
SELECT pg_current_wal_lsn(), pg_current_wal_insert_lsn();
SELECT pg_walfile_name(pg_current_wal_lsn());

-- Are we archiving successfully?
SELECT last_archived_wal, last_archived_time, failed_count, last_failed_wal, last_failed_time
FROM pg_stat_archiver;

-- Any slots holding WAL?
SELECT slot_name, active, restart_lsn, pg_size_pretty(
  pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS lag
FROM pg_replication_slots;
```

`last_failed_time` newer than `last_archived_time` is a page. Also alarming: growth in `pg_wal/` faster than archiving.

## Cloud notes

- **RDS/Aurora**: you don't configure `archive_command`. WAL is shipped to S3 automatically. PITR = point-and-click, choose a timestamp within the retention window. **Aurora** uses a different storage layer — no traditional WAL archiving on your part, and PITR is even more elastic.
- **Azure Flexible Server**: managed WAL archiving; enable geo-redundant backup for cross-region recovery. Choose PITR window on server creation.
- **Cloud SQL / AlloyDB**: enable "point-in-time recovery" (needs `enable_pitr` flag on Cloud SQL). Restore to another instance.

The concept — base backup + WAL — is identical. You only pay attention to it when self-hosting or troubleshooting.

## Worksheet

1. What's the smallest set of parameters you need to change to enable PITR on a self-hosted cluster?  
   _Answer:_ …

2. Sketch a WAL archiving pipeline for a fleet of 30 self-hosted clusters. Which shared components would you use and where does WAL-G/pgBackRest fit?  
   _Answer:_ …

3. Your monitoring says `pg_stat_archiver.failed_count = 812`. Walk through your triage in five bullets.  
   _Answer:_ …

4. Explain why a physical PITR restore requires the *same major version* on the target.  
   _Answer:_ …

5. On RDS, describe the exact clicks/CLI to restore `orders` accidentally dropped 40 minutes ago into a fresh instance.  
   _Answer:_ …

## References

- Continuous Archiving and PITR: https://www.postgresql.org/docs/current/continuous-archiving.html
- WAL configuration: https://www.postgresql.org/docs/current/wal-configuration.html
- pgBackRest user guide: https://pgbackrest.org/user-guide.html
- WAL-G: https://github.com/wal-g/wal-g
