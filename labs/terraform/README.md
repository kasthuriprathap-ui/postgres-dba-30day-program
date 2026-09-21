# Terraform Labs — PostgreSQL on AWS, Azure, GCP

Three parallel, runnable modules — one per cloud — that provision a production-shaped managed PostgreSQL. Same file layout, same operating philosophy, three different providers.

| Module | Provisions | Referenced by |
|---|---|---|
| [`rds-postgres/`](./rds-postgres/) | AWS RDS for PostgreSQL 16 with KMS, IAM DB auth, Multi-AZ toggle, Performance Insights, Enhanced Monitoring, RDS-managed Secrets Manager password | Day 15 |
| [`azure-flex-postgres/`](./azure-flex-postgres/) | Azure Database for PostgreSQL Flexible Server with VNet delegation, private DNS, Entra ID auth, zone-redundant HA toggle, `pgaudit` | Day 17 |
| [`gcp-cloudsql-postgres/`](./gcp-cloudsql-postgres/) | Cloud SQL for PostgreSQL with Private Service Access peering, regional HA, PITR, Query Insights, IAM DB users, Cloud SQL Auth Proxy pattern | Day 19 |

## Same shape across all three

Every module has:

```
versions.tf                # provider version pins + provider block
variables.tf               # typed inputs with validation
main.tf                    # every resource, in dependency order
outputs.tf                 # endpoint, admin credentials (sensitive), ready-to-copy connect command
terraform.tfvars.example   # copy → terraform.tfvars → edit
README.md                  # what it builds, how to connect, hygiene notes, teardown
```

Consistent variable names where the concept exists on both sides:

| Concept | RDS var | Azure Flex var | Cloud SQL var |
|---|---|---|---|
| Instance name | `name` | `name` | `name` |
| Location | `region` | `location` | `region` |
| PG major version | `engine_version` (`"16.3"`) | `postgresql_version` (`"16"`) | `database_version` (`"POSTGRES_16"`) |
| HA toggle | `multi_az` (bool) | `high_availability_mode` (string) | `availability_type` (string) |
| Backup retention | `backup_retention_days` | `backup_retention_days` | `backup_retention_days` |
| Cross-region backup | (via `copy_tags_to_snapshot` + separate copy) | `geo_redundant_backup` | (backup_configuration `location`) |
| Deletion protection | `deletion_protection` | (via `lifecycle`) | `deletion_protection` |
| Extension allowlist | (`shared_preload_libraries` in parameter group) | `enabled_extensions` + `azure.extensions` | `cloudsql.enable_*` flags |

## Recommended sequencing for the program

- **Day 15 (AWS)** — `terraform apply` the RDS module. This is the anchor lab.
- **Day 17 (Azure)** — apply the Azure module in a small subscription.
- **Day 19 (GCP)** — apply the Cloud SQL module.
- **Day 21** — compare the plans side-by-side. This is where the "same idea, different plumbing" clicks.
- **Day 30 (capstone)** — extend one of these modules with a read replica, PgBouncer/RDS Proxy, and a monitoring dashboard.

## Cost & safety

Each module's README ends with a cost note and a destroy command. Common cautions:

- **Public IP is disabled** in all three modules by default. Reach the DB from a bastion, VPN, private endpoint, or the cloud's Auth Proxy — not from your laptop's home Wi-Fi.
- **Deletion protection is on** by default. Destroy is a two-step (flip the flag, then destroy).
- **Random 24-char admin passwords** live in Terraform state. Rotate after apply and store the new value in Secrets Manager / Key Vault / Secret Manager — the module READMEs show how.
- **Budget alerts** — set them before you `terraform apply`.

See the top-level `CONNECTING.md` for the concrete recipes to reach each instance once provisioned.
