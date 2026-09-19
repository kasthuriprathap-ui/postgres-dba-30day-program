# Terraform lab — RDS for PostgreSQL

Provisions a production-shaped RDS PostgreSQL instance for the Day 15 lab.

## What it builds

- Customer-managed KMS key (with rotation).
- DB subnet group across the private subnets you provide.
- Security group that opens 5432 only to the CIDRs/SGs you specify.
- Parameter group with a sensible DBA baseline (`pg_stat_statements`, `auto_explain`, TLS forced, transaction/connection logging, idle-in-txn timeout).
- IAM role for Enhanced Monitoring.
- RDS PostgreSQL 16 instance:
  - `gp3` storage with autoscaling.
  - Storage & Performance Insights encryption with your KMS key.
  - **Master password managed by RDS + stored in Secrets Manager**.
  - IAM database authentication enabled.
  - Performance Insights (7 days) + Enhanced Monitoring (30 s).
  - CloudWatch log exports (`postgresql`, `upgrade`).
  - Deletion protection ON; final snapshot on destroy.

## Prerequisites

- Terraform ≥ 1.6, AWS CLI configured for the target account.
- An existing VPC with at least two subnets in different AZs. Private subnets preferred; the module creates no NAT/IGW.
- A budget alert on the target account.

## Quick start

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit: region, vpc_id, subnet_ids, allowed_cidrs (or allowed_security_group_ids)

terraform init
terraform plan  -out=tfplan
terraform apply tfplan
```

Provisioning takes about 8–12 minutes.

## Connect

```bash
export ENDPOINT=$(terraform output -raw rds_endpoint)
export SECRET_ARN=$(terraform output -raw master_password_secret_arn)

export PGPASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET_ARN" \
  --query SecretString --output text | jq -r .password)

psql "host=$ENDPOINT port=5432 dbname=appdb user=appadmin sslmode=require"
```

## Post-provision sanity checks

```sql
-- Version and RDS-specific settings
SELECT version();
SHOW shared_preload_libraries;
SHOW log_min_duration_statement;
SHOW rds.force_ssl;

-- Extensions on the allowlist
SELECT name FROM pg_available_extensions ORDER BY 1 LIMIT 20;

-- Enable the two you'll use every day
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- SSL is in effect for our session
SELECT ssl, version, cipher FROM pg_stat_ssl WHERE pid = pg_backend_pid();
```

## Enable IAM auth on a role

```sql
CREATE ROLE svc_iam LOGIN;
GRANT rds_iam TO svc_iam;
GRANT CONNECT ON DATABASE appdb TO svc_iam;
```

```bash
TOKEN=$(aws rds generate-db-auth-token \
  --hostname "$ENDPOINT" --port 5432 \
  --username svc_iam --region "$AWS_REGION")

PGPASSWORD="$TOKEN" psql \
  "host=$ENDPOINT port=5432 dbname=appdb user=svc_iam sslmode=require"
```

## Turn Multi-AZ on

```bash
terraform apply -var multi_az=true
```

A brief failover blip is possible. Use `apply_immediately` sparingly.

## Add a read replica (Day 22 preview)

Add to `main.tf`:

```hcl
resource "aws_db_instance" "replica" {
  identifier             = "${var.name}-ro"
  replicate_source_db    = aws_db_instance.this.identifier
  instance_class         = var.instance_class
  publicly_accessible    = false
  auto_minor_version_upgrade = true
  storage_encrypted      = true
  kms_key_id             = aws_kms_key.rds.arn
  skip_final_snapshot    = true
}
```

## Destroy

Deletion protection is on by default; disable, then destroy:

```bash
terraform apply -var deletion_protection=false -auto-approve
terraform destroy -auto-approve
```

## Cost note

The default sizing (`db.t4g.micro`, 20 GiB gp3, single-AZ, PI 7 days) is close to the always-free tier in eligible accounts. Multi-AZ roughly doubles the instance cost; Enhanced Monitoring at 30-second cadence is cents/day; PI at 7-day retention is free. Always check current pricing for your region.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `terraform apply` waits ~10 minutes then times out | RDS still provisioning; `terraform apply` again will resume |
| `Cannot connect` from your bastion | Security group ingress missing; add your CIDR/SG to `allowed_cidrs`/`allowed_security_group_ids` |
| `password authentication failed` | You fetched the secret before RDS finished rotating the initial password; wait 30 s and retry |
| `pg_stat_statements` missing | You applied but haven't rebooted; the param needs `pending-reboot`. Reboot in console or `terraform apply -var apply_immediately=true` after modifying the resource |
| Destroy blocked | Deletion protection still on; run the two-step in "Destroy" above |
