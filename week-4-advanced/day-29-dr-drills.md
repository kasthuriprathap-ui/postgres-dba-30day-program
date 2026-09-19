# Day 29 — Disaster Recovery Drills

## Objective

Design a DR posture, translate it into runbooks, and run at least one drill against your lab.

## Vocabulary

- **RPO (Recovery Point Objective)** — how much data you're willing to lose (time-window).
- **RTO (Recovery Time Objective)** — how long you're willing to be down.
- **BCP (Business Continuity Plan)** — the wider org-level plan; DR is a subset.

Every design decision this week has come back to RPO/RTO. This day is where you commit to numbers.

## The four scenarios you must handle

| Scenario | Detection | Mitigation | RPO/RTO typical |
|---|---|---|---|
| **Instance failure** (host/AZ) | Cloud health check | HA failover to standby | RPO 0, RTO ~1 min |
| **Region failure** | Regional-service outage | Failover to cross-region replica / secondary cluster | RPO seconds–minutes, RTO ~10–30 min |
| **Data corruption** (bug, human error) | App errors, dashboards | PITR to just before the event | RPO = duration since backup; RTO = restore time |
| **Backup corruption / rogue admin** | Monitoring; audit | Immutable/off-account backup; separate keys | Depends |

## The DR posture picker

Pick your worst tolerable RPO and RTO, then pick the topology:

| RPO / RTO | Topology |
|---|---|
| RPO 0, RTO < 2 min in-region | Managed HA (Multi-AZ / Zone-Redundant / Regional HA) |
| RPO seconds, RTO < 30 min cross-region | HA + cross-region read replica (async) |
| RPO 0 cross-region | Rare in PG world — application-level dual-write, or use Aurora Global with tradeoffs |
| RPO minutes, RTO hours | PITR + off-account/region snapshots |
| Any of the above + corruption tolerance | Immutable snapshots (S3 Object Lock / Immutable Vault / GCS Bucket Lock) |

## Runbook: cross-region failover for RDS (async replica)

Assumptions: prod in `us-east-1`, DR replica in `us-west-2`.

**Pre-checks (do these every week):**

- [ ] `aws rds describe-db-instances` — replica status = `available`
- [ ] Replica lag < 60 s (CloudWatch `ReplicaLag`).
- [ ] Backups on both regions healthy; `us-west-2` copy exists.
- [ ] DNS / connection string is behind a name that can be changed atomically.
- [ ] App reads sane on the DR replica (`select 1` from CI).

**Failover:**

1. Announce/acknowledge incident.
2. Ensure old primary can't accept writes (stop the app or `revoke connect on database`).
3. `aws rds promote-read-replica --db-instance-identifier prod-pg-dr`. Wait ~5–15 min.
4. Repoint DNS/app config to the promoted DR endpoint.
5. Verify by running a smoke suite: `SELECT count(*) FROM sales.orders; SELECT max(id) FROM sales.orders;` — compare against last snapshot.
6. Communicate.

**Aftermath:**

1. Build a new replica in the old region pointing at the new primary.
2. Decide whether to "fail back" — usually not; make DR region the new prod region if the failure caused a business-hour outage.

## Runbook: PITR restore of one table on Aurora

The table was truncated at `2026-09-16 14:30:00Z`.

1. `aws rds restore-db-cluster-to-point-in-time --source-db-cluster-identifier prod-aurora --db-cluster-identifier prod-aurora-restore --restore-to-time 2026-09-16T14:29:00Z`.
2. Wait for the cluster to be `available` and a writer instance to be `available`.
3. `psql` into the restored cluster; `pg_dump -t sales.orders` from restore → `pg_restore` (or `\i`) into prod.
4. Reconcile — sequences on prod may need to be advanced (`SELECT setval(...)`) to avoid PK collisions from the reinserted rows.
5. Drop the restored cluster.

## Runbook: Zone-redundant failover test (Azure Flexible Server)

Once a quarter. Always in maintenance window.

1. Communicate; ensure app has reconnect logic (retry on `57P01` — admin_shutdown).
2. Portal → server → Restart → check "Failover during restart" → run.
3. Watch: **primary AZ** value in the portal swaps.
4. `psql` reconnects; app healthchecks turn green.
5. Failover back after the drill so you don't leave both nodes in an unusual state.

## Practicing corruption recovery

The exercise SQL Server DBAs least often do — and the one where PG's tools shine.

```sql
-- Setup
CREATE TABLE sales.gold(k int primary key, v text);
INSERT INTO sales.gold SELECT g, md5(g::text) FROM generate_series(1, 100000) g;
SELECT now();       -- note this exactly

-- Cause damage
UPDATE sales.gold SET v = 'corrupt';
```

On cloud PITR (RDS/Aurora/Cloud SQL/AlloyDB/Azure Flex): restore to a new instance at the noted timestamp, extract `sales.gold`, import back.

## Testing your backups

A backup that has not been restored is a wish.

- Monthly: fully restore a snapshot to a new instance in a different account/subscription/project.
- Confirm row counts on the biggest 5 tables match what the source had at snapshot time.
- Delete the restore instance.

## The DR runbook template

Fill this in for your workload. Keep it short and tested.

```
# DR RUNBOOK — <workload>

Owner:
Last drill:
RPO target:
RTO target:

Detection:
- Cloud health event / alarm named …
- App alarm named …
- Manual signal …

Roles during incident:
- Incident commander:
- Comms:
- DB lead (you):
- App lead:

Pre-checks (weekly):
- [ ] Replica lag …
- [ ] Backup age …
- [ ] Firewall rules …

Failover steps:
1. …
2. …

Verification queries:
- SELECT count(*) FROM …

Rollback (if needed):
1. …

Post-incident:
- [ ] Rebuild the missing side
- [ ] Update this runbook with anything that surprised you
```

## Worksheet

1. Define RPO and RTO for the workload you spend the most time on. Justify each.  
   _Answer:_ …

2. Design the DR posture that best matches those numbers on your primary cloud.  
   _Answer:_ …

3. Turn one section of a DR runbook into a **script** you could run under stress. Which parts should stay manual?  
   _Answer:_ …

4. Explain why a Multi-AZ RDS is *not* DR.  
   _Answer:_ …

5. What's the trap in "we take snapshots every 6 hours; RPO is 6 hours"?  
   _Answer:_ …

## References

- AWS DR whitepaper: https://docs.aws.amazon.com/whitepapers/latest/disaster-recovery-workloads-on-aws/
- Azure BCDR for PG: https://learn.microsoft.com/azure/postgresql/flexible-server/concepts-business-continuity
- GCP DR docs: https://cloud.google.com/sql/docs/postgres/dr-plans
