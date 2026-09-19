# Day 19 — GCP Cloud SQL for PostgreSQL

## Objective

Provision a Cloud SQL for PostgreSQL instance (via `gcloud` and Terraform), understand HA, PITR, connection options (Cloud SQL Auth Proxy vs Private Service Connect), and how IAM database authentication works on GCP.

## Terminology bridge

| Concept | Cloud SQL |
|---|---|
| DB firewall / VPC integration | **Authorized networks** OR **Private IP** OR **Private Service Connect** |
| DB admin login | `postgres` role, or IAM-authenticated user |
| Backup vault | Automated backups (7 default, up to 365 with backup retention) + optional PITR |
| Log shipping | Read replicas (async) |
| Managed SQL Server login | IAM database authentication |

## Concepts

### Editions

- **Cloud SQL Enterprise** — the classic offering.
- **Cloud SQL Enterprise Plus** — better perf (up to 4× write throughput), near-zero downtime patching, and enhanced availability. Costs more. Same PG surface.

### Connectivity

Three ways to reach a Cloud SQL instance:

1. **Public IP + authorized networks** — quick and dirty. Not for prod.
2. **Private IP (VPC peering)** — a private range on your VPC via services networking. The default production path.
3. **Private Service Connect** — connect via a service attachment; scales better than VPC peering, works across VPCs and projects.

**Cloud SQL Auth Proxy** is a small binary you run alongside your app; it authenticates via Google Cloud IAM and creates a local encrypted tunnel to the instance. Your app connects to `127.0.0.1:5432` without knowing SSL/IP. Recommended for anything running outside GKE/Cloud Run.

### HA and read replicas

- **HA (regional)**: sync standby in another zone; failover ~60 s automatic.
- **Read replicas**: up to N in-region + cross-region, async. Can be promoted.
- **PITR**: WAL-based, up to 35 days when enabled.

### IAM database auth

- Enable `cloudsql.iam_authentication = on`.
- Grant the IAM role `roles/cloudsql.instanceUser` to a principal.
- Create the PG user: `CREATE USER "user@project.iam" WITH LOGIN;` (uses the IAM-mapped email).
- Auth via the Auth Proxy handles the token exchange.

## Provision — `gcloud` quickstart

```bash
gcloud sql instances create pgdba-lab \
  --database-version=POSTGRES_16 \
  --region=us-central1 \
  --tier=db-custom-2-4096 \
  --edition=ENTERPRISE \
  --availability-type=REGIONAL \
  --storage-type=SSD --storage-size=20 --storage-auto-increase \
  --backup-start-time=03:00 \
  --enable-point-in-time-recovery \
  --network=default \
  --no-assign-ip \
  --database-flags=cloudsql.iam_authentication=on,\
shared_preload_libraries=pg_stat_statements,\
log_min_duration_statement=500 \
  --maintenance-window-day=SUN \
  --maintenance-window-hour=04
```

Set the `postgres` password (or skip and rely on IAM):

```bash
gcloud sql users set-password postgres \
  --instance=pgdba-lab \
  --password='ChangeMe!' || true
```

Add an IAM user:

```bash
gcloud sql users create you@example.com \
  --instance=pgdba-lab --type=CLOUD_IAM_USER

# Grant the IAM role on the *instance*
gcloud sql instances add-iam-policy-binding pgdba-lab \
  --member=user:you@example.com \
  --role=roles/cloudsql.instanceUser
```

## Terraform snippet

```hcl
resource "google_sql_database_instance" "pg" {
  name             = "${var.name}-pg"
  region           = var.region
  database_version = "POSTGRES_16"

  settings {
    tier              = "db-custom-2-4096"
    edition           = "ENTERPRISE"
    availability_type = "REGIONAL"    # HA
    disk_type         = "PD_SSD"
    disk_size         = 20
    disk_autoresize   = true

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.vpc.id
      require_ssl     = true
    }

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      start_time                     = "03:00"
      transaction_log_retention_days = 7
      backup_retention_settings {
        retained_backups = 14
        retention_unit   = "COUNT"
      }
    }

    maintenance_window {
      day  = 7   # Sunday
      hour = 4
    }

    database_flags {
      name  = "cloudsql.iam_authentication"
      value = "on"
    }
    database_flags {
      name  = "shared_preload_libraries"
      value = "pg_stat_statements"
    }
    database_flags {
      name  = "log_min_duration_statement"
      value = "500"
    }
    database_flags {
      name  = "log_connections"
      value = "on"
    }
    database_flags {
      name  = "log_disconnections"
      value = "on"
    }

    insights_config {
      query_insights_enabled  = true
      record_application_tags = true
      record_client_address   = true
      query_string_length     = 4096
    }

    deletion_protection_enabled = true
  }

  deletion_protection = true
}

resource "google_sql_database" "appdb" {
  name     = "appdb"
  instance = google_sql_database_instance.pg.name
}

resource "random_password" "postgres" {
  length  = 24
  special = true
}

resource "google_sql_user" "postgres" {
  name     = "postgres"
  instance = google_sql_database_instance.pg.name
  password = random_password.postgres.result
}

# IAM DB user (map an IAM principal to a PG role)
resource "google_sql_user" "iam" {
  name     = "you@example.com"
  instance = google_sql_database_instance.pg.name
  type     = "CLOUD_IAM_USER"
}

resource "google_project_iam_member" "instance_user" {
  project = var.project_id
  role    = "roles/cloudsql.instanceUser"
  member  = "user:you@example.com"
}
```

## Connect via the Cloud SQL Auth Proxy

```bash
# Install: gcloud components install cloud-sql-proxy
cloud-sql-proxy PROJECT_ID:REGION:pgdba-lab-pg &

# Now psql talks to a local socket / port
psql "host=127.0.0.1 port=5432 dbname=appdb user=you@example.com sslmode=disable"
# SSL is provided by the proxy; the client-side sslmode is disable
```

For IAM auth, the proxy handles token acquisition when you pass `--auto-iam-authn`:

```bash
cloud-sql-proxy --auto-iam-authn PROJECT_ID:REGION:pgdba-lab-pg
```

## Query Insights

Enable it in `settings.insights_config` (done above). The console then shows:

- Top queries by execution time / rows / lock time.
- Per-query plan.
- Tagged application drill-down (add `application_name` in your DSN).

Insights is the closest thing to SQL Server Query Store on GCP.

## Worksheet

1. Which of the three connectivity options do you pick for prod and why?  
   _Answer:_ …

2. Explain in one paragraph how the Cloud SQL Auth Proxy differs from an SSH tunnel.  
   _Answer:_ …

3. Enable IAM auth on your instance and grant a group `data-analysts@example.com` read-only access to `appdb.reporting`. Sketch the steps.  
   _Answer:_ …

4. What's the effect of `deletion_protection` at Terraform vs at the API level? Which do you set? Both?  
   _Answer:_ …

5. Bonus: your instance is `PD_SSD`. What Cloud SQL feature would you turn on if I/O becomes the bottleneck?  
   _Answer:_ …

## References

- Cloud SQL for PostgreSQL: https://cloud.google.com/sql/docs/postgres
- Cloud SQL Auth Proxy: https://cloud.google.com/sql/docs/postgres/sql-proxy
- Terraform `google_sql_database_instance`: https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/sql_database_instance
- Query Insights: https://cloud.google.com/sql/docs/postgres/using-query-insights
- IAM database authentication: https://cloud.google.com/sql/docs/postgres/authentication
