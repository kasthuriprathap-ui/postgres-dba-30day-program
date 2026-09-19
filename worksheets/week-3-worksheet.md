# Week 3 Worksheet — Managed PostgreSQL on AWS, Azure, GCP

## A. AWS RDS (Day 15)

1. In the Terraform module at `labs/terraform/rds-postgres/`, which single variable flips the instance to Multi-AZ? Roughly what does that cost you?  
   _Answer:_ …

2. Extend the parameter group with `pgaudit` for `write, ddl`. What are the two resource changes?  
   _Answer:_ …

3. Which of these belongs in `apply_immediately = true`?  
   `instance_class` change; parameter group change with static params; `backup_retention_period` change; adding a security group.  
   _Answer:_ …

4. Refactor the module to consume an *existing* Secrets Manager secret you own for the master password. Sketch the diff.  
   _Answer:_ …

## B. AWS Aurora PG (Day 16)

5. Give two workload types where you pick Aurora over stock RDS PG.  
   _Answer:_ …

6. How would you use Aurora fast clones to give every pull request its own DB?  
   _Answer:_ …

7. Aurora Serverless v2 with `min=0.5, max=16` — what does that cap? What doesn't it cap?  
   _Answer:_ …

## C. Azure Flexible Server (Day 17)

8. Compare Public firewall / VNet integration / Private Endpoint. Which for prod? Why is switching hard later?  
   _Answer:_ …

9. Enable `pg_cron` on a running Flexible Server. Which two settings, and does either need a restart?  
   _Answer:_ …

## D. Azure HA & replicas (Day 18)

10. Design the topology for RPO 0 in-region + RTO ≤ 10 min for regional loss.  
    _Answer:_ …

11. During zone-redundant failover — what happens to open connections and what must the app handle?  
    _Answer:_ …

## E. GCP Cloud SQL (Day 19)

12. Which connectivity option do you pick for prod and why?  
    _Answer:_ …

13. Enable IAM DB auth and grant `data-analysts@example.com` read-only on `appdb.reporting`. Sketch the steps.  
    _Answer:_ …

## F. GCP AlloyDB (Day 20)

14. When do you pick AlloyDB over Cloud SQL? When would you not?  
    _Answer:_ …

15. Explain the read-pool topology. What determines read latency vs read throughput?  
    _Answer:_ …

## G. Cross-cloud decision (Day 21)

16. Fill in the scoring table for your current employer/app (see day-21 for template). Which offering wins and why?  
    _Answer:_ …

## Self-scoring

**Total: ___/16.** Ready for Week 4 at 13+.
