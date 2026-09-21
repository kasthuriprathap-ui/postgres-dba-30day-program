# Terraform lab — Cloud SQL for PostgreSQL

Provisions a private, HA-capable Cloud SQL for PostgreSQL instance for the Day 19 lab.

## What it builds

- (Optional) `google_compute_global_address` reserved range + `google_service_networking_connection` — the Private Service Access peering Cloud SQL private-IP requires. Skip when the VPC already has it.
- `google_sql_database_instance` with:
  - Private IP only (`ipv4_enabled = false`, VPC peered).
  - Requires SSL.
  - Regional HA by default (sync standby).
  - Automated backups + point-in-time recovery (WAL retained 7 days).
  - Query Insights enabled with per-query plans, client address, app tags.
  - Cloud SQL flags: IAM DB auth, `pgaudit`, `pg_cron`, `pg_stat_statements.track = ALL`, log_min_duration_statement = 500ms, plus the usual connection/lock/checkpoint logging.
  - Deletion protection at both the API and Terraform layers.
- `google_sql_database` for the initial application DB.
- `google_sql_user` for the built-in `postgres` role (random password).
- Optional IAM DB users + `roles/cloudsql.instanceUser` grants — pass a list of `{ email, type }` in `iam_members`.

## Prerequisites

- Terraform ≥ 1.6, `gcloud auth application-default login` completed for the target project.
- Enabled APIs on the project:
  ```
  gcloud services enable sqladmin.googleapis.com \
                         servicenetworking.googleapis.com \
                         compute.googleapis.com
  ```
- A VPC. If you don't already have Private Service Access set up, this module will do it — but it requires **Compute Network Admin** and **Service Networking Admin** on your identity.
- Budget alert on the project.

## Quick start

```bash
cp terraform.tfvars.example terraform.tfvars
# edit: project_id, network_id, region, tier

terraform init
terraform plan  -out=tfplan
terraform apply tfplan
```

Provisioning takes 8–15 min (regional HA is longer than zonal).

## Connect via the Cloud SQL Auth Proxy (recommended)

Cloud SQL private IP is unreachable from outside the VPC. The **Auth Proxy** solves this by opening an authenticated, encrypted tunnel from your workstation (or any Google-authenticated environment) to `127.0.0.1:5432`.

```bash
# Install once
gcloud components install cloud-sql-proxy
# or
brew install cloud-sql-proxy

# Start (leave running)
export CONN=$(terraform output -raw connection_name)
cloud-sql-proxy "$CONN"

# In another shell — password auth
export PW=$(terraform output -raw admin_password)
PGPASSWORD="$PW" psql "host=127.0.0.1 port=5432 dbname=appdb user=postgres sslmode=disable"
# sslmode=disable is correct: the proxy already provides mTLS
```

## Passwordless (IAM DB auth)

If you set `iam_authentication = true` and added yourself to `iam_members`:

```bash
cloud-sql-proxy --auto-iam-authn "$CONN"

psql "host=127.0.0.1 port=5432 dbname=appdb user=you@example.com sslmode=disable"
# Note: for IAM users the user name is your email; for service accounts,
# it's the SA email WITHOUT the ".gserviceaccount.com" suffix (docs shift on this — check with gcloud).
```

## Adding a read replica (Day 22)

Add to `main.tf`:

```hcl
resource "google_sql_database_instance" "replica" {
  name                 = "${var.name}-pg-ro"
  region               = var.region
  database_version     = var.database_version
  master_instance_name = google_sql_database_instance.this.name
  deletion_protection  = true

  settings {
    tier              = var.tier
    availability_type = "ZONAL"   # replicas are single-zone; the primary is HA
    edition           = var.edition
    disk_autoresize   = true

    ip_configuration {
      ipv4_enabled    = false
      private_network = var.network_id
      require_ssl     = true
    }
  }
}
```

Replicas replicate asynchronously. Promotion is one-way.

## Production hygiene

- [ ] Rotate the `postgres` password after apply and store it in Secret Manager; delete it from state.
      Terraform pattern:
      ```hcl
      resource "google_secret_manager_secret" "pg_admin" { … }
      resource "google_secret_manager_secret_version" "pg_admin" {
        secret_data = google_sql_user.postgres.password
        secret      = google_secret_manager_secret.pg_admin.id
      }
      ```
- [ ] Prefer IAM DB auth for humans and service accounts; leave `postgres` unused day-to-day.
- [ ] `edition = ENTERPRISE_PLUS` if you need near-zero-downtime maintenance and higher write throughput.
- [ ] Turn on **Cross-Region Backups** (via `settings.backup_configuration.location` set to a different region) — not exposed in this module by default.

## Destroy

```bash
# Deletion protection is on. Turn it off first.
terraform apply -var deletion_protection=false -auto-approve
terraform destroy -auto-approve
```

If `create_private_service_access = true` was used, destroying will also remove the peering — do that only if no other Cloud SQL / Memorystore / Filestore instance in this VPC depends on it.

## Cost note

Rough monthly ranges (list price, us-central1):

| Config | ~USD/mo |
|---|---|
| `db-f1-micro`, zonal (sandbox, no HA) | $8–12 |
| `db-custom-2-4096`, zonal | $80–100 |
| `db-custom-2-4096`, regional (HA) | $160–200 |
| Enterprise Plus, same size | +30–60% |

Terraform destroy releases everything.
