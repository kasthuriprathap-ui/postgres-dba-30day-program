# Day 21 — Cross-Cloud Comparison and Decision Framework

## Objective

Produce a one-page mental model you can use in any architecture conversation to pick the right managed PostgreSQL. Consolidate everything from Days 15–20.

## The two decisions, in order

1. **Which cloud?** — usually already decided by the rest of your platform. If not: which cloud does the app live in? Where's the data? Where are the humans?
2. **Which offering within that cloud?** — this is where you use the table below.

## Managed PostgreSQL matrix

| Capability | AWS RDS PG | AWS Aurora PG | Azure Flexible Server | GCP Cloud SQL PG | GCP AlloyDB |
|---|---|---|---|---|---|
| Storage model | Provisioned EBS gp3/io | Distributed, shared, log-based | Provisioned managed disk | Provisioned PD | Distributed, shared, log-based |
| Max DB size | 64 TiB | 128 TiB | 32 TiB | 64 TiB | 128 TiB |
| HA | Multi-AZ (sync standby) | Storage-native + fast failover | Zone-redundant or Same-zone (sync) | Regional (sync standby) | Native (compute-decoupled) |
| Failover time | ~60–120 s | ~30 s (writer node) | ~60–120 s | ~60 s | seconds |
| Read replicas | Up to 15 physical | Up to 15, ~ms lag | Up to 5, async | Multiple, async | Read pool (elastic) |
| Cross-region | Cross-region read replica | **Global Database** (sub-second) | Cross-region read replica | Cross-region read replica | Cross-region **secondary cluster** |
| Serverless | (RDS Serverless not GA for PG at present) | Aurora Serverless v2 | No (auto-pause on Burstable only) | No | No |
| SQL Server T-SQL compat | No | **Babelfish** | No | No | No |
| Backups & PITR | 0–35 days | Continuous, 1–35 days | 1–35 days + LTR | 1–365 days retention; PITR up to 35 | Continuous, 1–35 days |
| IAM DB auth | Yes | Yes | Entra ID auth | Yes | Yes |
| Fast clones | No | Yes | No | No | Yes |
| Extensions ecosystem | RDS allowlist (broad) | Aurora allowlist (broad, some Aurora-only) | Azure allowlist (broad) | Cloud SQL flags (broad) | AlloyDB allowlist (broad + columnar) |
| Analytics acceleration | pgvector, PostGIS | pgvector, PostGIS | pgvector, PostGIS | pgvector, PostGIS | **Columnar engine**, AlloyDB AI |
| Query observability | Performance Insights + Enh Monitoring | Same | Query Store + Insights + Log Analytics | Query Insights | Query Insights + system_insights |
| Native pooler | RDS Proxy | RDS Proxy | Built-in PgBouncer | (via proxies/apps) | Built-in |
| SLA (typical) | 99.95% (Multi-AZ) | 99.99% (cluster) | 99.99% (Zone-redundant HA) | 99.95% (HA) | 99.99% (HA) |
| Terraform | `aws_db_instance` | `aws_rds_cluster` + `aws_rds_cluster_instance` | `azurerm_postgresql_flexible_server` | `google_sql_database_instance` | `google_alloydb_cluster` + `_instance` |

## Decision heuristics

**Pick RDS PG when:**

- The rest of the stack is on AWS.
- Workload is small-to-medium OLTP, cost-sensitive.
- You want the closest to community PostgreSQL.

**Pick Aurora PG when:**

- The rest of the stack is on AWS, and any of:
  - You need many read replicas / global read scale.
  - You want zero-touch scaling with Serverless v2.
  - You need to lift a T-SQL app quickly (Babelfish).

**Pick Azure Flexible Server when:**

- The rest of the stack is on Azure.
- You need Entra ID auth and VNet integration.
- You need pgvector, PostGIS, `pg_cron`, `citus` on managed PG.

**Pick Cloud SQL when:**

- The rest of the stack is on GCP.
- Workload is small-to-medium; costs matter; you like the Auth Proxy pattern.

**Pick AlloyDB when:**

- On GCP, and any of:
  - Mixed OLTP + analytics that benefits from the columnar engine.
  - Heavy read scale via a read pool.
  - pgvector search at scale.

## The migration lens

If you're migrating **from SQL Server** (Day 26 goes deep):

| Situation | Preferred landing |
|---|---|
| Lots of T-SQL, ad-hoc, stored procs, no time to refactor | **Aurora PG + Babelfish** |
| Well-factored app, ORM-based | Any managed PG — pick by cloud |
| Analytics-heavy | Aurora PG or AlloyDB |
| Small OLTP, budget-tight | RDS PG or Cloud SQL |

## Provisioning parity — one line each

| Service | Fast bootstrap |
|---|---|
| RDS PG | `terraform apply` on `labs/terraform/rds-postgres` |
| Aurora PG | `aws_rds_cluster` + one `aws_rds_cluster_instance` (`db.serverless`) |
| Azure Flex | `azurerm_postgresql_flexible_server` with VNet delegation |
| Cloud SQL | `gcloud sql instances create ... --database-version=POSTGRES_16` |
| AlloyDB | `gcloud alloydb clusters create` + `gcloud alloydb instances create` |

## Worksheet — capstone-ready

Score your current employer/app in this table:

| Factor | Weight (1–5) | AWS RDS | Aurora | Azure Flex | Cloud SQL | AlloyDB |
|---|---|---|---|---|---|---|
| Same cloud as app |  |  |  |  |  |  |
| Data locality / residency |  |  |  |  |  |  |
| Cost sensitivity |  |  |  |  |  |  |
| Read scale needs |  |  |  |  |  |  |
| Analytics needs |  |  |  |  |  |  |
| DR reach (multi-region) |  |  |  |  |  |  |
| T-SQL compatibility |  |  |  |  |  |  |
| pgvector / AI |  |  |  |  |  |  |
| Team familiarity |  |  |  |  |  |  |
| **Total** |  |  |  |  |  |  |

Whichever column wins is your recommendation. Justify one paragraph.

## Personal cheat sheet (fill in)

- The one thing surprising to me about **RDS PG**: …
- The one thing surprising to me about **Aurora**: …
- The one thing surprising to me about **Azure Flex**: …
- The one thing surprising to me about **Cloud SQL**: …
- The one thing surprising to me about **AlloyDB**: …

Onward to Week 4 — where you take these building blocks and put them into production shape.
