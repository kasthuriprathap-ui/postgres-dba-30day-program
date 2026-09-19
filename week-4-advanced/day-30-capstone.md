# Day 30 — Capstone Project

## Objective

Pull the whole month together. In a single 4–6 hour block (or split over a weekend), design and build a *production-shaped* PostgreSQL deployment for a workload of your choice.

## The brief

Choose one:

- **Migrate a SQL Server workload** you actually know to a managed PG on your primary cloud.
- **Green-field**: launch a new service that requires PG and design it end-to-end.

Either way, the deliverable is a **README-driven runbook** covering everything below.

## The rubric

You can call yourself "PG DBA-ready on cloud" when the deliverables below exist and are consistent with each other.

### 1. Requirements doc (30 min)

- Workload profile: read/write ratio, TPS, avg row size, data volume, growth rate, connection concurrency.
- Availability target (SLA %).
- **RPO** and **RTO** — real numbers, not "as good as possible."
- Data classification (PII? regulated?).
- Team access model (roles).
- Budget envelope.

### 2. Architecture (45 min)

- Cloud + offering (RDS / Aurora / Flex / Cloud SQL / AlloyDB) — cite Day 21 matrix.
- Instance size baseline + scaling plan.
- Network: VPC/VNet, private endpoints, security groups.
- HA topology.
- DR topology (in-region + cross-region if required).
- Pooler decision (RDS Proxy / built-in / PgBouncer / none).
- Backup + retention.
- Extension list to install on day 1.
- Encryption (KMS keys, key rotation).

### 3. IaC (60–90 min)

- Terraform (or Bicep/Deployment Manager) module that provisions everything you designed.
- Uses `labs/terraform/rds-postgres` as a starting point when applicable.
- Includes: KMS key, subnet group, security group, parameter group, DB instance, HA/replica.
- Secrets in Secrets Manager / Key Vault / Secret Manager.
- Outputs: endpoint, secret ARN, KMS ARN.

### 4. Schema, roles, and RLS (30 min)

- DDL for one representative table with realistic types (`bigint IDENTITY`, `jsonb`, `timestamptz`, `numeric`).
- The 4-role model (`app_owner`, `app_rw`, `app_ro`, `app_deploy`).
- `ALTER DEFAULT PRIVILEGES` for future tables.
- One RLS policy if multi-tenant.

### 5. Observability (30 min)

- `pg_stat_statements` + `auto_explain` enabled.
- List of 8 alerts with thresholds.
- Which dashboards you'd rely on (cloud + Grafana if applicable).

### 6. Migration or bootstrap plan (30 min)

- If migration: SCT/DMS or Babelfish plan, cutover window, rollback strategy.
- If green-field: initial data seeding, first-week ramp-up plan.

### 7. Runbooks (45 min)

Write short (≤10 lines) runbooks for:

- Deploy a schema migration.
- Add/rotate an app role's credentials.
- PITR a dropped table.
- Fail over to standby / cross-region replica.
- Emergency killswitch: put the DB in read-only mode.

### 8. DR drill result (30 min)

- Run one drill against a scratch instance.
- Report actual RTO measured. Compare with target.

## Grading yourself

For each item above, mark it 0 (nothing), 1 (draft), 2 (complete). You are DBA-ready at 14/16 total.

## Presentation (optional)

If you can, present the capstone to a peer or a friendly senior DBA. Their questions will surface gaps faster than any self-review.

## What to do after Day 30

- Take the on-call rotation for the workload you built.
- Contribute to the extension ecosystem — most extensions welcome PRs.
- Read one PG changelog per release. Since PG 12 the changes are surprisingly readable.
- Subscribe to the PG hackers mailing list (skim; participate when you can).
- If you enjoyed the migration path, become fluent in DMS + SCT — they're a rare skill combo.
- Take a look at PgConf videos on YouTube. Two hours a month keeps you current.

## Closing thought

You started 30 days ago with a SQL Server mind. That's a good place to have started — SQL Server DBAs bring rigor, sense of ownership, and a healthy suspicion of magic. PostgreSQL rewards all of those. What you traded in return is *transparency*: the ability to look at a plan, a WAL record, a lock, a snapshot, and know exactly what the engine is doing.

Keep the daily worksheets. In six months, run through them again. You'll be surprised how much has stuck — and where you finally understand what you only memorized this month.

Good luck out there.
