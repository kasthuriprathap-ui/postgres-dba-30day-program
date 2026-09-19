# Week 2 — Core PostgreSQL Administration

**Goal:** by Sunday you can back up and restore any PG database (logically and physically), configure PITR, keep autovacuum healthy, choose the right index type, read `EXPLAIN` plans, and tune the top 15 parameters that matter.

| Day | Topic | SQL Server analogue |
|---|---|---|
| 8 | Backup & restore: `pg_dump`, `pg_restore`, `pg_basebackup` | `BACKUP DATABASE` FULL / DIFF |
| 9 | WAL, archiving, and Point-in-Time Recovery | Transaction log backups + STOPAT |
| 10 | VACUUM, autovacuum, bloat, and freeze | Statistics + ghost cleanup |
| 11 | Indexes: B-tree, GIN, GiST, BRIN, hash, partial, expression, INCLUDE | Rowstore, filtered, columnstore |
| 12 | Reading query plans with `EXPLAIN (ANALYZE, BUFFERS)` | Actual execution plan |
| 13 | Parameter tuning: `shared_buffers` to `random_page_cost` | `sp_configure`, trace flags |
| 14 | Week 2 review + worksheet | |

Everything this week is engine-level, so it applies verbatim to RDS, Flexible Server, Cloud SQL, and AlloyDB. The next week we'll see which of these knobs vendors give you and which they hide.
