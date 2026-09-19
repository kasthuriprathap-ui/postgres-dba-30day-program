# Day 23 — High-Availability Patterns

## Objective

Compare the mainstream HA patterns for PostgreSQL: cloud-managed (RDS Multi-AZ, Aurora, Flexible Server HA, Cloud SQL HA, AlloyDB), self-managed with **Patroni**, and simpler pgpool/`repmgr` setups. Pick one for your workload and explain the failure modes.

## SQL Server → PostgreSQL bridge

| SQL Server | PostgreSQL equivalent |
|---|---|
| Always On AG listener | HAProxy in front of Patroni, or cloud writer endpoint, or `Pgpool-II` |
| WSFC (Windows Server Failover Cluster) | etcd/Consul/ZooKeeper + Patroni |
| Sync commit AG | `synchronous_commit = remote_apply`, `synchronous_standby_names = 'ANY 1 (...)'` |
| Automatic seeding | `pg_basebackup -R` |
| Manual failover | `patronictl switchover`, or cloud API |
| Read-scale AG | Physical replicas + a route (LB, Patroni's read-only endpoint) |

## Concepts

### Three tiers of HA

1. **Cloud-managed** — you pay a bit more, don't build anything, and get a predictable SLA. This is the right default in 2026 unless you have a reason otherwise.
2. **Patroni + etcd (or Consul/ZooKeeper)** — the community standard for self-managed HA. Automates leader election, failover, standby rebuild.
3. **Warm standby with human-in-the-loop** — smallest and simplest, but no automatic failover. Only for tiny/dev workloads.

### Patroni in one page

Patroni is a Python agent per node. Nodes coordinate through **DCS** (etcd is most common). One node holds a lock and acts as the leader; the others follow, using `pg_basebackup`/`pg_rewind` to reseed as needed.

Topology:

```
      ┌───────── etcd cluster (3 or 5 nodes) ─────────┐
      │                                              │
   ┌──▼──┐         ┌──────┐         ┌──────┐         │
   │pat A│◄────────┤pat B ├────────►│pat C │◄────────┘
   │pg   │         │pg    │         │pg    │
   │(pri)│         │(std) │         │(std) │
   └──▲──┘         └──▲───┘         └──▲───┘
      │              │                │
     (app traffic via HAProxy or PgBouncer with `db_probe`)
```

Minimal Patroni YAML for one node:

```yaml
scope: pgdba
name: node-a

restapi:
  listen: 0.0.0.0:8008
  connect_address: 10.0.0.10:8008

etcd3:
  hosts: 10.0.0.20:2379,10.0.0.21:2379,10.0.0.22:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576   # 1 MB
    synchronous_mode: true             # sync commit to at least one replica
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        wal_level: replica
        max_wal_senders: 10
        max_replication_slots: 10
        hot_standby: 'on'

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 10.0.0.10:5432
  data_dir: /var/lib/postgresql/16/data
  authentication:
    replication: {username: replicator, password: 'x'}
    superuser:   {username: postgres,   password: 'x'}
  pg_hba:
    - host all all 10.0.0.0/8 scram-sha-256
    - host replication replicator 10.0.0.0/8 scram-sha-256

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
```

Fronting Patroni with HAProxy that probes `/master` and `/replica`:

```
frontend fe_pg
  bind *:5000
  default_backend be_pg_primary

backend be_pg_primary
  option httpchk GET /master
  http-check expect status 200
  server a 10.0.0.10:5432 check port 8008 inter 2s
  server b 10.0.0.11:5432 check port 8008 inter 2s
  server c 10.0.0.12:5432 check port 8008 inter 2s
```

App uses `haproxy:5000` (writer) and (optionally) another port (`5001`) for readers.

### Cloud-managed HA — the abstractions

- **RDS Multi-AZ**: a synchronous standby in a second AZ. The DB DNS name repoints on failover; you get one endpoint.
- **Aurora**: primary + replicas share storage. Failover promotes any replica in ~30 s. Two endpoints: writer, reader.
- **Azure Flexible Server**: same-zone or zone-redundant HA (sync standby). One endpoint.
- **Cloud SQL**: regional HA (sync standby). One endpoint.
- **AlloyDB**: primary + read pool + optional cross-region secondary cluster. Multi-endpoint.

All hide `pg_basebackup`/`pg_rewind`/etcd/Patroni. You still need to know they exist so you can reason about failure modes.

### Failure modes to think about

| Failure | Cloud-managed | Patroni |
|---|---|---|
| Primary VM host dies | DNS repoints ~60–120 s | Patroni promotes standby ~30–60 s |
| Standby VM host dies | Rebuild silently | Patroni reseeds via `pg_basebackup` |
| Network partition | Vendor handles | Two-node split-brain risk without quorum DCS |
| Storage subsystem incident | Region-scope; use cross-region DR | Storage-scoped; separate WAL archive still fine |
| Human `DROP TABLE` | PITR only | PITR only |
| Long-running txn blocks failover | Standby lags, failover slower | Patroni can promote but you'll see brief lag |

### PgBouncer in the HA path

Because clients connect per session and reconnect on failover, PgBouncer between app and PG saves a lot of connection cost during and after failover. Prefer `pool_mode = transaction`. Configure the DB backend to point at the writer endpoint or HAProxy front-end.

## Runbooks

### A. Planned failover on RDS Multi-AZ

1. Alert stakeholders.
2. Verify replica lag < 100 KB (RDS console → replication).
3. `aws rds reboot-db-instance --db-instance-identifier <id> --force-failover`.
4. Watch the DNS TTL to expire (~60 s), confirm reconnects, run smoke checks.

### B. Planned switchover on Patroni

```bash
patronictl -c /etc/patroni.yml switchover
# Choose the new primary, confirm; expect 5–20 s of write pause.
```

### C. Emergency reseeding on Patroni

If a standby diverged beyond `maximum_lag_on_failover`, Patroni marks it `stopped`. To rebuild:

```bash
patronictl reinit pgdba node-b
```

## Worksheet

1. Design an HA topology for a 2 TB PG workload with 99.99% target SLA. Consider Patroni vs Aurora vs Azure Zone-redundant HA. Argue for one, then argue for another.  
   _Answer:_ …

2. Why is a 2-node etcd cluster dangerous? What's the minimum you'd deploy?  
   _Answer:_ …

3. Aurora's failover is ~30 s. What happens to in-flight write transactions during that window?  
   _Answer:_ …

4. Draw the request path with PgBouncer + HAProxy + Patroni + 3 PG nodes.  
   _Answer:_ …

5. Bonus: how do you tell if `synchronous_commit = remote_apply` is costing you throughput vs `remote_write`?  
   _Answer:_ …

## References

- Patroni docs: https://patroni.readthedocs.io/
- PostgreSQL Warm Standby: https://www.postgresql.org/docs/current/warm-standby.html
- HAProxy check for Patroni: https://patroni.readthedocs.io/en/latest/rest_api.html
