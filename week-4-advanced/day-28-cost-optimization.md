# Day 28 — Cost Optimization

## Objective

Learn the levers that meaningfully change a managed PG bill, and build a habit of checking them monthly.

## The five levers

1. **Compute (instance class / tier / ACU).** Right-size first, then commit.
2. **Storage — size, IOPS, and throughput.** Autoscale, don't overprovision.
3. **Data movement.** Backups across regions, replicas across regions, egress.
4. **HA/DR.** Turning HA on ~doubles compute. Cross-region replicas cost their full compute.
5. **License / edition.** RDS PG is open-source; you pay for the compute, not the DB. But: Aurora I/O-Optimized, AlloyDB, Azure Enterprise editions have different rate cards.

## Compute

- **Baseline sizing = P95 of a normal week, not the peak.** Cloud lets you resize; use it.
- **Reserved instances / committed use / savings plans**: 1–3 year commit ⇒ 25–60% off. Only commit what you're sure about (long-lived prod).
- **Serverless where variable**: Aurora Serverless v2, Cloud SQL "scale to zero" for burst dev. Watch cold-start behavior.
- **Read replicas costed like primaries.** Don't over-provision readers "for safety."

## Storage

- **`gp3` (AWS) is almost always cheaper than `gp2` at equivalent perf.** Provision IOPS and throughput explicitly.
- **Auto-scaling storage**: set a `max_allocated_storage` ceiling so you don't blow the budget on runaway WAL.
- **Snapshot retention**: 7 days is often plenty for automated; keep monthly LTR outside the platform.
- **Cross-region snapshot copies**: real cost per GB per month; only for prod DR.

## Data transfer

- **Same-region same-AZ**: cheap.
- **Cross-AZ**: has per-GB egress cost; Multi-AZ HA replication is included, cross-AZ app traffic is not.
- **Cross-region**: expensive per GB. Consider logical replication vs raw stream costs.
- **Internet egress**: even worse. Keep app in the same region as the DB, or use private endpoints.

## HA & replicas

Right-size the standby to the primary; anything smaller may fail the promotion later. For DR-only cross-region replicas, consider smaller/pausable instances if you accept slower recovery.

## Cost queries and dashboards

### On the DB

Track top storage consumers:

```sql
SELECT
  schemaname||'.'||relname AS table,
  pg_size_pretty(pg_total_relation_size(schemaname||'.'||relname)) AS total,
  pg_size_pretty(pg_relation_size(schemaname||'.'||relname))       AS heap,
  pg_size_pretty(pg_indexes_size(schemaname||'.'||relname))        AS indexes
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(schemaname||'.'||relname) DESC
LIMIT 20;

-- Unused indexes (cost you disk and write amplification)
SELECT relname, idx_scan, pg_size_pretty(pg_relation_size(indexrelid))
FROM pg_stat_user_indexes
WHERE idx_scan = 0
ORDER BY pg_relation_size(indexrelid) DESC;
```

### AWS

- **Cost Explorer** grouped by service = RDS + tag by Env/Owner.
- **AWS Budgets**: set a monthly alert.
- **RDS pricing tags** (`copy_tags_to_snapshot = true`) — makes snapshot cost visible per team.
- **Trusted Advisor / Compute Optimizer** — right-sizing recommendations.

### Azure

- **Cost Management** with Flexible Server metrics.
- **Advisor** shows right-sizing and reservation opportunities.

### GCP

- **Billing reports** with SQL query on BigQuery export.
- **Recommender** for Cloud SQL right-sizing.

## Anti-patterns

1. **A giant instance for one giant query.** Instead: partition, add an index, or offload to a replica.
2. **Long retention on non-critical logs.** Ship to cheap storage, prune the DB logs.
3. **`work_mem` tuned globally huge.** Multiplied across connections it wastes memory and drives you to a bigger instance.
4. **Snapshot retention forever "just in case."** Rotate; store LTR in cheap object storage.
5. **A Multi-AZ standby that no one ever fails over to.** Test it (Day 29) so the cost is buying real availability, not comfort.
6. **Cross-region read replica used for reporting.** Egress + double compute; usually a same-region replica plus a monthly logical replica for DR is cheaper.
7. **Never running `VACUUM FULL` / `pg_repack` on the biggest table.** Bloat is stored data you pay for.

## Concrete: right-size an RDS instance

Weekly report to check:

```sql
-- Historical connection count
SELECT date_trunc('hour', now() - i * interval '1 hour') AS h,
       0::int AS placeholder
FROM generate_series(0, 168) i;   -- pair with CloudWatch DatabaseConnections

-- Cache hit ratio
SELECT round(100 * sum(heap_blks_hit) /
             NULLIF(sum(heap_blks_hit + heap_blks_read), 0), 2) AS heap_hit_pct
FROM pg_statio_user_tables;

-- Top wait events over a load window
SELECT wait_event_type, wait_event, count(*)
FROM pg_stat_activity WHERE state = 'active'
GROUP BY 1,2 ORDER BY 3 DESC LIMIT 10;
```

Combine with CloudWatch CPU/IOPS/Memory. If CPU < 40% during peak for a month and cache hit > 99%, size down one class and observe.

## Worksheet

1. List three ways to shrink a PG bill *without changing app code*.  
   _Answer:_ …

2. When would you pick Aurora Serverless v2 despite a higher per-hour rate?  
   _Answer:_ …

3. Explain how unused indexes cost you money (three vectors).  
   _Answer:_ …

4. Design a 90-day cost review checklist for a 20-instance managed PG fleet.  
   _Answer:_ …

5. Bonus: your R2 (log storage) grew from 10 GB to 400 GB in a month. Two DB-side causes?  
   _Answer:_ …

## References

- AWS pricing calculator: https://calculator.aws
- Azure pricing calculator: https://azure.microsoft.com/pricing/calculator/
- GCP pricing calculator: https://cloud.google.com/products/calculator
- AWS Compute Optimizer for RDS: https://docs.aws.amazon.com/compute-optimizer/latest/ug/view-rds-recommendations.html
