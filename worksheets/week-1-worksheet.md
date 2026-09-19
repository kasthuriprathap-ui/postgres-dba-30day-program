# Week 1 Worksheet — Fundamentals

**How to use this:** Fill in your answers directly in this file (or copy it to a personal notebook). Aim for 45–60 minutes total. Reference the day-specific worksheets in each `week-1-fundamentals/day-XX.md` for hints.

## A. Architecture (Day 1)

1. Draw the cluster → database → schema → object hierarchy from memory. (Sketch and describe in 3–4 sentences.)  
   _Answer:_ …

2. Explain "one connection = one process" and its two operational consequences.  
   _Answer:_ …

3. Map each SQL Server thing to its PG equivalent:  
   a. `tempdb` → …  
   b. `sys.dm_exec_sessions` → …  
   c. `BACKUP LOG` → …  
   d. Filegroup → …  
   e. Server-scoped role → …  

## B. Installation & connectivity (Day 2)

4. Write the exact `pg_hba.conf` line that forces SSL, uses SCRAM, allows `analytics_ro` from `10.20.0.0/16`, only to the `warehouse` DB.  
   _Answer:_ …

5. Which of these parameters need a restart? Circle them.  
   `shared_buffers`, `work_mem`, `max_connections`, `log_min_duration_statement`, `wal_level`  
   _Answer:_ …

## C. psql (Day 3)

6. Add three lines you'd put in a production `~/.psqlrc`.  
   _Answer:_ …

7. Write a one-liner `psql` command that prints the row count of `sales.orders` with no headers/formatting, and exits non-zero on failure.  
   _Answer:_ …

## D. Types & schemas (Day 4)

8. Convert this SQL Server DDL to idiomatic PG:  
   ```sql
   CREATE TABLE dbo.Users (
     UserID INT IDENTITY(1,1) PRIMARY KEY,
     Email NVARCHAR(320) NOT NULL UNIQUE,
     CreatedAtUTC DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
     IsActive BIT NOT NULL DEFAULT 1,
     Metadata NVARCHAR(MAX) NULL
   );
   ```  
   _Answer:_ …

9. Explain `timestamp` vs `timestamptz` in two sentences you'd say to a developer.  
   _Answer:_ …

## E. Roles & security (Day 5)

10. Design a role model for a 2-tenant SaaS where each tenant has RW on its schema and BI has RO cross-tenant. Include `ALTER DEFAULT PRIVILEGES`.  
    _Answer:_ …

11. A junior added `sales.audit_log` and BI can't see it. Why, and what should you have done?  
    _Answer:_ …

## F. MVCC & transactions (Day 6)

12. Why can a "small" long-lived transaction grow a 100 GB table into 400 GB?  
    _Answer:_ …

13. Pick the isolation level for each and justify:  
    a. OLTP debit/credit → …  
    b. Nightly reporting → …  
    c. Daily aggregation with reads and writes → …  

14. Which three timeouts do you set on any production cluster and to what values?  
    _Answer:_ …

## G. Self-scoring

- Section A: ___/3
- Section B: ___/2
- Section C: ___/2
- Section D: ___/2
- Section E: ___/2
- Section F: ___/3

**Total: ___/14.** You're ready for Week 2 at 11+.
