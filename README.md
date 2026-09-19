# 30-Day PostgreSQL DBA Program (for SQL Server DBAs)

A structured 30-day plan to build production-grade PostgreSQL administration skills on **AWS, Azure, and GCP**, taught through the lens of a **SQL Server DBA**. Every day includes: a short concept brief, a SQL Server ↔ PostgreSQL bridge, hands-on examples you can run locally or in the cloud, and a worksheet you can fill in.

---

## Who this is for

You already know SQL Server: T-SQL, SSMS, Always On, backups, DMVs, Query Store, Agent jobs. You want to become fluent in PostgreSQL — both the engine and the three big managed offerings (RDS/Aurora, Azure Database for PostgreSQL Flexible Server, Cloud SQL/AlloyDB) — in a single month.

## How to use the program

- **1 hour/day minimum**, 2 hours ideal. Each day is scoped to fit that.
- Work through the `.md` for the day, run the examples, then complete the worksheet.
- Keep a lab environment (see `labs/`) running — repetition is where the muscle memory forms.
- Don't skip Week 1 even if you feel eager to jump to cloud. Managed PG is still PG; the surprises live in the engine.

## Program at a glance

| Week | Theme | Days |
|------|-------|------|
| 1 | PostgreSQL fundamentals for the SQL Server mind | 1–7 |
| 2 | Core administration: backup, WAL, vacuum, indexes, tuning | 8–14 |
| 3 | Managed PostgreSQL on AWS, Azure, GCP | 15–21 |
| 4 | Advanced ops: replication, HA, security, monitoring, migration, DR, capstone | 22–30 |

## Daily lesson layout

Each day file follows the same shape so you can pattern-match quickly:

1. **Objective** — what you will be able to do by the end of the day
2. **SQL Server → PostgreSQL bridge** — how the concept maps from what you already know
3. **Concepts** — the material, kept tight
4. **Hands-on examples** — copy/paste ready SQL and shell commands
5. **Cloud notes** — AWS, Azure, GCP specifics where they matter
6. **Worksheet** — exercises to prove you understood it
7. **References** — links to the authoritative docs

## Lab environment

You have three options; pick one and stick with it:

1. **Local Docker** (recommended for Weeks 1–2). See `labs/docker-compose-local-postgres.yml`.
2. **A tiny managed instance in one cloud** (e.g., RDS `db.t4g.micro`, Cloud SQL `db-f1-micro`, Azure Flexible Server Burstable B1ms). Cheapest for Weeks 3–4.
3. **All three clouds** in parallel — do this only if you want the direct comparison feel.

Load the sample schema in `labs/sample-schema.sql` on day 2 and reuse it throughout.

## Deliverables you'll produce

By day 30 you will have:

- A working PostgreSQL lab (local + at least one cloud).
- A personal SQL Server → PostgreSQL translation notebook (built via the daily worksheets).
- A migration runbook draft (day 26) and a DR runbook (day 29).
- A capstone: end-to-end deployment, migration, monitoring, and DR plan for one workload of your choice (day 30).

## Folder map

```
postgres-dba-30day-program/
├── README.md                                  ← you are here
├── SQL_SERVER_TO_POSTGRES_CHEATSHEET.md       ← keep this open every day
├── CONNECTING.md                              ← every connection recipe, per cloud
├── week-1-fundamentals/
│   ├── README.md
│   ├── day-01-architecture.md
│   ├── day-02-installation-connectivity.md
│   ├── day-03-psql-toolkit.md
│   ├── day-04-datatypes-schemas.md
│   ├── day-05-roles-security.md
│   ├── day-06-mvcc-transactions.md
│   └── day-07-week1-review.md
├── week-2-core-admin/
│   ├── README.md
│   ├── day-08-backup-restore.md
│   ├── day-09-wal-pitr.md
│   ├── day-10-vacuum-bloat.md
│   ├── day-11-indexes.md
│   ├── day-12-query-plans-explain.md
│   ├── day-13-tuning-parameters.md
│   └── day-14-week2-review.md
├── week-3-cloud/
│   ├── README.md
│   ├── day-15-aws-rds-postgres.md
│   ├── day-16-aws-aurora-postgres.md
│   ├── day-17-azure-flexible-server.md
│   ├── day-18-azure-ha-replication.md
│   ├── day-19-gcp-cloud-sql.md
│   ├── day-20-gcp-alloydb.md
│   └── day-21-cross-cloud-compare.md
├── week-4-advanced/
│   ├── README.md
│   ├── day-22-replication.md
│   ├── day-23-ha-patterns.md
│   ├── day-24-security-hardening.md
│   ├── day-25-monitoring-observability.md
│   ├── day-26-migration-from-sqlserver.md
│   ├── day-27-extensions.md
│   ├── day-28-cost-optimization.md
│   ├── day-29-dr-drills.md
│   └── day-30-capstone.md
├── worksheets/
│   ├── week-1-worksheet.md
│   ├── week-2-worksheet.md
│   ├── week-3-worksheet.md
│   └── week-4-worksheet.md
└── labs/
    ├── docker-compose-local-postgres.yml
    ├── sample-schema.sql
    └── terraform/
        └── rds-postgres/          ← full Terraform module used on Day 15
            ├── main.tf
            ├── variables.tf
            ├── outputs.tf
            ├── versions.tf
            ├── terraform.tfvars.example
            └── README.md
```

## Companion references

- [`SQL_SERVER_TO_POSTGRES_CHEATSHEET.md`](SQL_SERVER_TO_POSTGRES_CHEATSHEET.md) — the daily translation guide. Keep it open in a split pane.
- [`CONNECTING.md`](CONNECTING.md) — every connection recipe: `psql`, DBeaver, and cloud-specific patterns (bastion, SSM port forward, Cloud SQL Auth Proxy, Entra ID auth, IAM DB auth). Reach for this whenever the answer to "how do I get in?" is not obvious.

## A quick word before you start

The single biggest trap for SQL Server DBAs learning Postgres is assuming "database" means the same thing. It doesn't. Also: **there is no shared TempDB, no clustered index, no SQL Agent, and no maintenance plans**. What Postgres gives you instead is honest, composable primitives — MVCC, WAL, extensions, roles — that you assemble to fit the workload. Once that clicks, you will find it liberating.

Let's go.
