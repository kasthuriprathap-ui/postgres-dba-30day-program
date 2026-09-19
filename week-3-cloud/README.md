# Week 3 — Managed PostgreSQL on AWS, Azure, GCP

**Goal:** by Sunday you can provision, connect to, and operate managed PostgreSQL on all three clouds, understand the HA and read-scale options for each, and produce a defensible short list for a new workload.

| Day | Topic | Deliverable |
|---|---|---|
| 15 | AWS RDS for PostgreSQL + **full Terraform lab** | A running RDS instance you provisioned with `terraform apply` |
| 16 | AWS Aurora PostgreSQL-Compatible | Understand storage separation, cluster endpoints, Global Database |
| 17 | Azure Database for PostgreSQL — Flexible Server | An Azure Flexible Server (portal or Terraform) |
| 18 | Azure HA, read replicas, and burstable vs GP vs Memory tiers | HA mental model, tier picker |
| 19 | GCP Cloud SQL for PostgreSQL | A Cloud SQL instance via `gcloud`/Terraform |
| 20 | GCP AlloyDB for PostgreSQL | AlloyDB architecture and when to use it |
| 21 | Cross-cloud comparison and decision framework | A one-page "how do I pick?" matrix |

## What "managed" changes and what it doesn't

**Changes** — the cloud handles the OS, the storage, HA plumbing, patching, monitoring dashboards, backup infrastructure, and (usually) TLS certificates. You do not `SSH`, you do not touch `postgresql.conf` directly, and you do not run `pg_basebackup` for the base backup.

**Does not change** — everything from Weeks 1–2. `pg_stat_activity` still tells you who's connected. `EXPLAIN (ANALYZE, BUFFERS)` still reads the same. Autovacuum is still critical. `pg_stat_statements` is still your best friend. `psql` is still the client.

This is why Weeks 1–2 came first.

## Money warning

You will spin up real cloud resources this week. Rules:

1. Use the smallest instance size (`db.t4g.micro`, `Standard_B1ms`, `db-f1-micro`, `alloydb-omni` local, etc.).
2. **Tear it down** at the end of each day unless you're using it in a later day.
3. Set a **budget alert** in each cloud before you begin.
4. Prefer single-AZ, no cross-region backups during the tutorial.
