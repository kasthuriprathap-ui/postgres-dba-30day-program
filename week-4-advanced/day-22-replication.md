# Day 22 — Replication: Streaming and Logical

## Objective

Set up both **physical streaming replication** and **logical replication** on a self-hosted cluster, understand replication slots, and know which flavor to use for which job.

## SQL Server → PostgreSQL bridge

| SQL Server | PostgreSQL |
|---|---|
| Always On AG (sync/async) | Physical streaming replication (`synchronous_commit`, `synchronous_standby_names`) |
| Log shipping | WAL archiving + `restore_command` on a warm standby |
| Transactional replication | Logical replication (publications/subscriptions) |
| Merge replication | Not a first-class feature; roll your own with triggers or use CDC + pipeline |
| Snapshot replication | Initial copy on subscription creation |
| Availability Group listener | An external LB (HAProxy) or Patroni + REST endpoints, or cloud writer/reader endpoint |

## Concepts

### Physical (streaming) replication

- WAL from the primary streams over TCP to the standby.
- The standby applies WAL constantly; a `SELECT` on the standby sees the state as of the last applied record.
- Standbys are **read-only**. Can be sync or async.

**Roles on the primary:**

```sql
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'x';
-- pg_hba.conf:
host replication replicator 10.0.0.0/8 scram-sha-256
```

**Bootstrap the standby with `pg_basebackup`:**

```bash
pg_basebackup -h primary -U replicator -D /var/lib/postgresql/16/data \
              -Fp -X stream -R -c fast -P
# -R writes standby.signal and primary_conninfo
```

Start the server. It will connect, replay WAL, and stay in recovery.

**Sync vs async on the primary:**

```
synchronous_commit          = remote_apply     # or 'on' for remote flush
synchronous_standby_names   = 'ANY 1 (standby1,standby2)'  # quorum
```

Sync means the primary's `COMMIT` waits until at least one named standby has flushed (or applied). Trade-off: latency of the write path grows to at least one round trip.

### Replication slots

A **replication slot** stops the primary from recycling WAL that a standby (or logical consumer) still needs. Two flavors:

- **Physical slots** — pinned to a physical standby.
- **Logical slots** — a decoding pipeline for logical replication or CDC.

**Warning:** an inactive slot pins WAL forever. This is the #1 cause of runaway `pg_wal/` growth in the wild. Monitor `pg_replication_slots.active` and `pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)`.

### Logical replication

Row-level, publication/subscription model. Works between different major versions and can replicate a subset of tables. Uses a logical slot on the source.

Requires `wal_level = logical` on the publisher.

**On the publisher:**

```sql
CREATE PUBLICATION shop_pub FOR TABLE sales.customers, sales.orders;
-- ...or all tables in one or more schemas (PG15+):
CREATE PUBLICATION shop_all FOR TABLES IN SCHEMA sales;
```

**On the subscriber (different cluster, can be different version):**

```sql
CREATE SUBSCRIPTION shop_sub
  CONNECTION 'host=publisher user=repl_user password=x dbname=shop'
  PUBLICATION shop_pub
  WITH (copy_data = true, create_slot = true, enabled = true);
```

Subscribers replicate `INSERT`/`UPDATE`/`DELETE`/`TRUNCATE`, plus (PG16+) sequences on demand. Neither DDL nor large-object changes flow — you manage schema changes separately.

**Requirements for logical replication:**

- Every replicated table needs a **replica identity** (PK is best; `REPLICA IDENTITY FULL` works but is expensive).
- Users writing on the subscriber can cause conflicts — the subscription pauses on conflict; you resolve and `ALTER SUBSCRIPTION ... SKIP`.
- Sequences are not fully replicated automatically (PG16+ improves this).

### When to use which

| Situation | Choice |
|---|---|
| Standby for HA / failover | Physical streaming |
| Read-scaling with strict lag SLA | Physical streaming, multiple standbys |
| Zero-downtime major version upgrade (14 → 16) | Logical replication (build a 16 subscriber, cut over) |
| Move a subset of data to an analytics DB | Logical replication |
| CDC to Kafka / event stream | Logical decoding + `wal2json` / `pgoutput` (via Debezium) |
| Cross-cloud DR | Logical replication over VPN / peering |

### Cloud reality

- Managed clouds do physical streaming for you (Multi-AZ standbys, read replicas). You don't touch it.
- Logical replication is fully available: enable `wal_level=logical` (parameter/flag), grant `rds_replication` (RDS)/`replication` (Azure/GCP) role.
- Cross-cloud logical replication works today — a common pattern to migrate between clouds.

## Hands-on

### Local streaming replication with Docker

Extend `docker-compose-local-postgres.yml` (lab file) with a second service:

```yaml
services:
  pgdba:
    # existing primary...
    environment:
      POSTGRES_INITDB_ARGS: "--wal-segsize=64"
    command: >
      postgres
      -c wal_level=logical
      -c max_wal_senders=10
      -c max_replication_slots=10
      -c hot_standby=on

  pgdba-standby:
    image: postgres:16
    depends_on: [pgdba]
    volumes:
      - pgdba_standby_data:/var/lib/postgresql/data
    command: >
      bash -c "
        rm -rf /var/lib/postgresql/data/* &&
        PGPASSWORD=postgres pg_basebackup -h pgdba -U postgres -D /var/lib/postgresql/data -Fp -X stream -R -c fast -P &&
        exec docker-entrypoint.sh postgres -c hot_standby=on
      "
```

On the primary create the replication user first:

```sql
ALTER USER postgres WITH REPLICATION;
```

Verify:

```sql
-- On the primary
SELECT client_addr, state, sync_state, sent_lsn, write_lsn, flush_lsn, replay_lsn
FROM pg_stat_replication;

-- On the standby
SELECT pg_is_in_recovery();     -- t
SELECT * FROM pg_stat_wal_receiver;
```

### Local logical replication

Publisher (existing `shop`) — set `wal_level=logical`, restart, then:

```sql
CREATE ROLE repl_user LOGIN REPLICATION PASSWORD 'x';
GRANT USAGE ON SCHEMA sales TO repl_user;
GRANT SELECT ON ALL TABLES IN SCHEMA sales TO repl_user;
CREATE PUBLICATION shop_pub FOR TABLES IN SCHEMA sales;
```

Subscriber (fresh DB):

```sql
CREATE DATABASE shop_analytics;
\c shop_analytics
-- Recreate the empty schema and tables (same DDL)
CREATE SCHEMA sales; ...

CREATE SUBSCRIPTION shop_sub
  CONNECTION 'host=publisher dbname=shop user=repl_user password=x'
  PUBLICATION shop_pub
  WITH (copy_data = true);
```

Watch the lag:

```sql
-- Publisher
SELECT slot_name, active, restart_lsn,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS lag
FROM pg_replication_slots;
```

### CDC preview

For CDC to a message bus, use the `pgoutput` plugin (built-in) with a tool like **Debezium** or a Kafka connector. Managed platforms (AWS DMS, Azure DMS, GCP Datastream) also consume PG logical decoding.

## Failing over safely

1. Stop writes on the primary (application-level guard or `ALTER SYSTEM SET default_transaction_read_only = on` + reload — advisory, not enforced against a role with `BYPASSRLS`).
2. Verify `pg_stat_replication.replay_lsn` on the primary equals `pg_current_wal_lsn()` — no lag.
3. Promote the standby: `SELECT pg_promote(wait := true, wait_seconds := 60);`
4. Update DNS / connection strings.
5. Rebuild the old primary as a new standby of the new primary.

## Worksheet

1. Sketch the difference between `pg_stat_replication` (on primary) and `pg_stat_wal_receiver` (on standby).  
   _Answer:_ …

2. Given `synchronous_standby_names = 'ANY 2 (a,b,c)'` — what does a `COMMIT` wait for? What if `b` is down?  
   _Answer:_ …

3. Your `pg_wal/` grew from 4 GB to 400 GB overnight. Where do you look first?  
   _Answer:_ …

4. Write the DDL for a logical replication setup where you publish only `sales.orders` and require row-level filter `where tenant_id = 42`. (PG 15+.)  
   _Answer:_ …

5. Bonus: What's the RPO of a logical subscription lagging 5 seconds if the primary is destroyed?  
   _Answer:_ …

## References

- Streaming replication: https://www.postgresql.org/docs/current/warm-standby.html#STREAMING-REPLICATION
- Logical replication: https://www.postgresql.org/docs/current/logical-replication.html
- Replication slots: https://www.postgresql.org/docs/current/warm-standby.html#STREAMING-REPLICATION-SLOTS
- Debezium PostgreSQL connector: https://debezium.io/documentation/reference/stable/connectors/postgresql.html
