# Day 18 — Azure Flexible Server: HA, Read Replicas, and Failover

## Objective

Understand Flexible Server's HA topologies, when to add read replicas, how failover and maintenance work, and how to plan a DR posture across regions.

## SQL Server → Azure PG bridge

| SQL Server IaaS/PaaS | Flexible Server |
|---|---|
| Always On AG (sync + async replicas) | Zone-redundant HA (sync) + async read replicas |
| SQL Managed Instance failover group | Cross-region read replica (async) + planned promotion |
| Failover Cluster Instance | Same-zone HA (sync) |
| Log shipping | Read replicas |
| ADR (Accelerated Database Recovery) | Not applicable — MVCC + WAL semantics differ |

## Concepts

### HA topologies

| Topology | RPO | RTO | Cost | Notes |
|---|---|---|---|---|
| **Single server, no HA** | Backup interval (5 min WAL) | Rebuild time (10–30 min) | 1× | Only for dev/test. |
| **Same-zone HA** | 0 (sync standby) | ~60–120 s | 2× compute | Standby in same AZ. Failure domain: rack/host. |
| **Zone-redundant HA** | 0 | ~60–120 s | 2× compute + inter-AZ traffic | Standby in different AZ. Recommended default for prod. |
| **HA + cross-region read replica** | Seconds behind | Minutes (async promote) | 2× + replica cost | Regional DR. |

You **cannot** enable HA on Burstable-tier servers. Choose GP or Memory Optimized for HA.

### What "HA on" actually gives you

- A hot standby PG server, receiving WAL synchronously (`synchronous_commit = on`).
- Automatic failover — Azure fabric detects, promotes standby, and updates the DNS endpoint. Existing connections drop; new connections succeed.
- **Backups run against the primary only.** You lose no backup capability during failover; you may briefly lose the ability to run a new backup.
- Extension changes and parameter changes replicate.

### Read replicas

- Up to **5** async replicas per primary.
- Same region or cross-region.
- Each has its own endpoint. Applications route reads explicitly.
- **You cannot write to a replica** and you cannot promote a replica back to a replica of the original.
- Promotion breaks the replication link permanently — it's a one-way operation.

Common pattern: 1 same-region replica for BI + 1 cross-region replica for DR.

### Failovers you can trigger

- **Planned failover** — user-initiated for maintenance testing. Roles swap.
- **Forced failover** — simulate incident; may cause data loss if async standby was chosen (not the case with sync HA).
- **Restart with failover** — Azure Portal → Restart → "Failover during restart."

Managed services on all three clouds usually let you drill failover on demand. **Do it quarterly.** (Day 29.)

### Maintenance and patching

Set a custom maintenance window (day of week, hour). Azure patches minor versions during the window; HA cushions the impact — the standby is patched first, failover, then the previous primary patched and becomes the new standby.

## Hands-on

### Trigger a failover from the CLI

```bash
az postgres flexible-server restart \
  --resource-group rg-pgdba \
  --name pgdba-lab-pg \
  --failover Forced
```

Confirm from `psql`:

```sql
-- Check primary/standby availability zone from portal or REST API
-- Observe your connection drop and reconnect
```

### Create a read replica

```bash
az postgres flexible-server replica create \
  --replica-name pgdba-lab-pg-ro \
  --resource-group rg-pgdba \
  --source-server pgdba-lab-pg
```

### Promote a replica for DR

```bash
az postgres flexible-server replica promote \
  --name pgdba-lab-pg-ro \
  --resource-group rg-pgdba \
  --promote-mode standalone \
  --promote-option forced
```

Terraform equivalent for a replica:

```hcl
resource "azurerm_postgresql_flexible_server" "replica" {
  name                          = "${var.name}-pg-ro"
  resource_group_name           = azurerm_resource_group.pg.name
  location                      = azurerm_resource_group.pg.location
  create_mode                   = "Replica"
  source_server_id              = azurerm_postgresql_flexible_server.this.id
  sku_name                      = "GP_Standard_D2ds_v5"
  version                       = azurerm_postgresql_flexible_server.this.version
  delegated_subnet_id           = azurerm_subnet.pg.id
  private_dns_zone_id           = azurerm_private_dns_zone.pg.id
  storage_mb                    = azurerm_postgresql_flexible_server.this.storage_mb
  backup_retention_days         = 7
}
```

## Monitoring the pipeline

- **Replication lag**: Azure Monitor metric `pg_replica_log_delay_in_seconds` and `pg_replica_log_delay_in_bytes`.
- **Connections**: `pg_stat_replication` on the primary shows the standby.
- **HA status**: portal shows "Available" / "Standby-Available" / "Failing over".

## DR posture — the classic trade-off

| Goal | Choice |
|---|---|
| RPO 0, RTO ~1 min, one region | Zone-redundant HA |
| RPO seconds, RTO ~5–10 min, region loss | HA + cross-region read replica; promote on DR |
| RPO minutes, cost-sensitive | Cross-region read replica only |
| RPO 0 and cross-region | Not supported on Flexible Server today; achieve with logical replication or app-level dual-write |

## Worksheet

1. A workload needs RPO 0 within region and RTO ≤ 10 min for regional loss. Design the topology.  
   _Answer:_ …

2. Explain what happens to *your open connections* on a zone-redundant failover. What does your app need to handle?  
   _Answer:_ …

3. You need to promote the cross-region replica. List two things that break immediately and how you'd address them.  
   _Answer:_ …

4. Difference between `promote-option forced` and `planned`? When is each safe?  
   _Answer:_ …

5. Bonus: draft a runbook for a quarterly DR test — 5 bullets.  
   _Answer:_ …

## References

- Flexible Server HA: https://learn.microsoft.com/azure/postgresql/flexible-server/concepts-high-availability
- Read replicas: https://learn.microsoft.com/azure/postgresql/flexible-server/concepts-read-replicas
- Maintenance and failover: https://learn.microsoft.com/azure/postgresql/flexible-server/concepts-maintenance
