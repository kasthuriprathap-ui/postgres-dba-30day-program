# Week 4 Worksheet — Advanced Operations

## A. Replication (Day 22)

1. Difference between `pg_stat_replication` (primary) and `pg_stat_wal_receiver` (standby)?  
   _Answer:_ …

2. `synchronous_standby_names = 'ANY 2 (a,b,c)'` — what does COMMIT wait for? What if `b` is down?  
   _Answer:_ …

3. `pg_wal/` grew from 4 GB to 400 GB overnight. Where do you look first?  
   _Answer:_ …

4. Logical replication that publishes only `sales.orders WHERE tenant_id = 42` (PG 15+). Show DDL.  
   _Answer:_ …

## B. HA patterns (Day 23)

5. Design HA for a 2 TB PG workload targeting 99.99%. Compare Patroni vs Aurora vs Azure ZR-HA. Pick one, then argue the alternative.  
   _Answer:_ …

6. Why is 2-node etcd dangerous? Minimum you'd deploy?  
   _Answer:_ …

## C. Security (Day 24)

7. `pgaudit` config for a bank: DDL, role changes, and reads on `sales.customers.ssn`.  
   _Answer:_ …

8. `FORCE ROW LEVEL SECURITY` vs plain RLS — difference and when to use each.  
   _Answer:_ …

## D. Monitoring (Day 25)

9. Pick five alerts and set defensible thresholds for your workload.  
   _Answer:_ …

10. Query that lists top 10 tables by dead-tuple percentage and last autovacuum time.  
    _Answer:_ …

## E. Migration from SQL Server (Day 26)

11. When Babelfish beats SCT + DMS — one paragraph.  
    _Answer:_ …

12. Convert to PG: `SELECT TOP 5 * FROM dbo.Users WITH (NOLOCK) WHERE UpdatedAt > DATEADD(day, -1, GETDATE());`  
    _Answer:_ …

13. Two SQL Server features with no clean PG mapping.  
    _Answer:_ …

## F. Extensions (Day 27)

14. Right extension for each:  
    a. In-DB scheduler → …  
    b. Hypothetical index test → …  
    c. Shrink 500 GB bloated table without downtime → …  
    d. 1536-dim embeddings → …  
    e. Audit logs of role changes → …  

15. Write a `pg_cron` job to `ANALYZE sales.orders` every night at 03:15.  
    _Answer:_ …

## G. Cost (Day 28)

16. Three ways to shrink a PG bill without changing app code.  
    _Answer:_ …

17. 90-day cost review checklist for a 20-instance managed PG fleet.  
    _Answer:_ …

## H. DR drills (Day 29)

18. RPO & RTO for your primary workload. Justify each.  
    _Answer:_ …

19. Runbook (5 bullets) for PITR restore of one accidentally dropped table.  
    _Answer:_ …

20. Why is Multi-AZ *not* DR?  
    _Answer:_ …

## I. Capstone (Day 30)

21. Deliverables you produced. Grade each 0/1/2. Total?  
    _Answer:_ …

## Self-scoring

**Total: ___/21.** Program complete at 17+. Congratulations.
