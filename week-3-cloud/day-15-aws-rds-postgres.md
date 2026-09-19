# Day 15 — AWS RDS for PostgreSQL (with Terraform)

## Objective

Provision a production-shaped Amazon RDS for PostgreSQL instance using **Terraform**, connect to it, understand parameter groups, subnet groups, security groups, KMS encryption, and IAM authentication. By the end of today you have a running instance that you built entirely from code.

## SQL Server → PostgreSQL bridge (on AWS)

| Amazon RDS for SQL Server concept | Amazon RDS for PostgreSQL concept |
|---|---|
| DB Option group (SQL Server features) | DB Option group not used; feature toggles live in the parameter group and extension allowlist |
| Native backup to S3 (`msdb`) | Automated snapshot + WAL to S3 (managed); manual snapshots on demand |
| Windows Authentication | IAM database authentication (short-lived tokens) |
| SQL Server Agent | EventBridge Scheduler / Lambda / `pg_cron` extension |
| CDC / CT | Logical replication (via `wal_level=logical`) and DMS |
| SSMS | `psql`, pgAdmin, DBeaver, Azure Data Studio + PG ext |
| Always On (RDS Multi-AZ Custom) | Multi-AZ RDS (standby, sync replication) |
| Migrating on-prem to RDS | AWS DMS + Schema Conversion Tool (SCT); or **Babelfish for Aurora PostgreSQL** if T-SQL-heavy |

## Concepts

### The RDS building blocks

1. **DB Subnet Group** — the set of subnets (across ≥2 AZs) RDS can place ENIs in. Must be private if you want a private DB.
2. **Security Group** — port 5432 open to your app/bastion.
3. **DB Parameter Group** — your `postgresql.conf` substitute. `family = "postgres16"`; parameters `pg_stat_statements`, `log_min_duration_statement`, `shared_preload_libraries`, etc.
4. **Option Group** — mostly empty for PG (SQL Server-heavy concept).
5. **DB Instance** — the actual server: engine version, instance class, storage type (`gp3` almost always), Multi-AZ, backup retention, maintenance window.
6. **KMS key** — for storage encryption. Best practice: your own customer-managed key.
7. **Secrets Manager** — for the master password. RDS can now **manage the master password** automatically and store it in Secrets Manager with rotation.
8. **IAM auth** — enable at the instance level, then `GRANT rds_iam TO db_user;`. Auth token generated per connection.
9. **Performance Insights + Enhanced Monitoring** — turn both on; free/cheap and invaluable.

### RDS-specific extension model

Extensions are controlled by the parameter `rds.extensions`. You can only `CREATE EXTENSION` for extensions on that list. Common ones to expect: `pg_stat_statements`, `pgcrypto`, `pg_cron`, `pg_partman`, `pgvector`, `postgis`, `hll`, `hypopg`, `pg_repack`.

### Where `SUPERUSER` went

There is no `SUPERUSER` on RDS. The master user gets **`rds_superuser`**, which can do almost everything a DBA needs but cannot access the underlying OS. There is also `rdsadmin` (an internal role you don't use).

### Backups on RDS

- Automated: daily snapshot + continuous WAL, retained 0–35 days.
- Manual snapshots: no expiration; you can copy them across regions and accounts.
- PITR: pick any second within your retention window.
- Restore always produces a **new instance** (endpoint changes).

## The Terraform lab

Full working project at `labs/terraform/rds-postgres/`. Here's the architecture and the highlights.

### What you'll create

```
  ┌────────────────────────────────────────────────────────┐
  │ VPC (yours — supply via variables)                      │
  │                                                        │
  │  private-subnet-a       private-subnet-b               │
  │        │                     │                          │
  │  ┌─────┴──────────┬──────────┴─────┐                    │
  │  │   RDS DB subnet group          │                    │
  │  │   ┌──────────────────────┐     │                    │
  │  │   │  RDS PostgreSQL 16   │◄────┘ Multi-AZ standby   │
  │  │   │  gp3, KMS encrypted  │                          │
  │  │   │  IAM auth on         │                          │
  │  │   │  PI + Enh Mon on     │                          │
  │  │   └──────────────────────┘                          │
  │  │        ▲                                            │
  │  │        │ 5432                                       │
  │  │ Security Group (only from app SG)                   │
  └──┼────────┼──────────────────────────────────────────────┘
     │        │
   app SG   Secrets Manager (master password, auto-rotated)
```

### Prerequisites

- An AWS account you own and a role with `AdministratorAccess` (or a scoped policy).
- `terraform` ≥ 1.6, AWS CLI configured.
- An existing VPC with at least two private subnets in different AZs. (The lab does not create the VPC — that's a separate concern and would triple the code.)
- Region and default budget alert already set.

### Quick start (from the lab)

```bash
cd labs/terraform/rds-postgres/
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: region, vpc_id, subnet_ids, allowed_cidrs

terraform init
terraform plan  -out=tfplan
terraform apply tfplan
# ~10 minutes

# Read the endpoint + fetch the password:
terraform output rds_endpoint
aws secretsmanager get-secret-value \
  --secret-id "$(terraform output -raw master_password_secret_arn)" \
  --query SecretString --output text | jq -r .password

# Connect
psql "host=$(terraform output -raw rds_endpoint) port=5432 dbname=appdb user=appadmin sslmode=require"
```

Full details in `labs/terraform/rds-postgres/README.md`.

### The four files, condensed

**`versions.tf`** — pin providers:

```hcl
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws    = { source = "hashicorp/aws",    version = "~> 5.60" }
    random = { source = "hashicorp/random", version = "~> 3.6"  }
  }
}
provider "aws" { region = var.region }
```

**`variables.tf`** — the knobs:

```hcl
variable "region"            { type = string }
variable "name"              { type = string  default = "pgdba-lab" }
variable "vpc_id"            { type = string }
variable "subnet_ids"        { type = list(string) }   # >= 2 in different AZs
variable "allowed_cidrs"     { type = list(string) }   # who can hit 5432
variable "instance_class"    { type = string  default = "db.t4g.micro" }
variable "allocated_storage" { type = number  default = 20 }
variable "max_allocated_storage" { type = number default = 100 }
variable "multi_az"          { type = bool    default = false }
variable "backup_retention_days" { type = number default = 7 }
variable "engine_version"    { type = string  default = "16.3" }
variable "db_name"           { type = string  default = "appdb" }
variable "master_username"   { type = string  default = "appadmin" }
variable "deletion_protection" { type = bool  default = true }
variable "tags"              { type = map(string) default = {} }
```

**`main.tf`** — the resources:

```hcl
resource "aws_kms_key" "rds" {
  description             = "KMS key for RDS PostgreSQL: ${var.name}"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = var.tags
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-subnets"
  subnet_ids = var.subnet_ids
  tags       = var.tags
}

resource "aws_security_group" "rds" {
  name        = "${var.name}-rds-sg"
  description = "PostgreSQL access to ${var.name}"
  vpc_id      = var.vpc_id
  tags        = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "pg_from_allowed" {
  for_each          = toset(var.allowed_cidrs)
  security_group_id = aws_security_group.rds.id
  ip_protocol       = "tcp"
  from_port         = 5432
  to_port           = 5432
  cidr_ipv4         = each.value
  description       = "PostgreSQL from ${each.value}"
}

resource "aws_vpc_security_group_egress_rule" "all_out" {
  security_group_id = aws_security_group.rds.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "All outbound"
}

resource "aws_db_parameter_group" "this" {
  name        = "${var.name}-pg16"
  family      = "postgres16"
  description = "Managed by Terraform (Day 15 lab)"

  parameter { name = "shared_preload_libraries" value = "pg_stat_statements,auto_explain" apply_method = "pending-reboot" }
  parameter { name = "pg_stat_statements.track" value = "ALL" }
  parameter { name = "log_min_duration_statement" value = "500" }
  parameter { name = "auto_explain.log_min_duration" value = "500" }
  parameter { name = "auto_explain.log_analyze" value = "1" }
  parameter { name = "log_connections" value = "1" }
  parameter { name = "log_disconnections" value = "1" }
  parameter { name = "log_lock_waits" value = "1" }
  parameter { name = "idle_in_transaction_session_timeout" value = "600000" } # 10 min
  parameter { name = "statement_timeout" value = "0" } # tune per role/DB
  parameter { name = "rds.force_ssl" value = "1" }
  tags = var.tags
}

resource "aws_iam_role" "rds_monitoring" {
  name = "${var.name}-rds-monitoring"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_db_instance" "this" {
  identifier                    = var.name
  engine                        = "postgres"
  engine_version                = var.engine_version
  instance_class                = var.instance_class
  allocated_storage             = var.allocated_storage
  max_allocated_storage         = var.max_allocated_storage
  storage_type                  = "gp3"
  storage_encrypted             = true
  kms_key_id                    = aws_kms_key.rds.arn

  db_name                       = var.db_name
  username                      = var.master_username
  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.rds.arn

  db_subnet_group_name          = aws_db_subnet_group.this.name
  vpc_security_group_ids        = [aws_security_group.rds.id]
  parameter_group_name          = aws_db_parameter_group.this.name

  multi_az                      = var.multi_az
  publicly_accessible           = false
  iam_database_authentication_enabled = true

  backup_retention_period       = var.backup_retention_days
  backup_window                 = "03:00-04:00"
  maintenance_window            = "sun:04:30-sun:05:30"
  copy_tags_to_snapshot         = true
  delete_automated_backups      = false
  deletion_protection           = var.deletion_protection

  performance_insights_enabled          = true
  performance_insights_kms_key_id       = aws_kms_key.rds.arn
  performance_insights_retention_period = 7
  monitoring_interval                   = 30
  monitoring_role_arn                   = aws_iam_role.rds_monitoring.arn

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  auto_minor_version_upgrade = true
  apply_immediately          = false
  skip_final_snapshot        = false
  final_snapshot_identifier  = "${var.name}-final-${formatdate("YYYYMMDDhhmm", timestamp())}"

  tags = var.tags

  lifecycle {
    ignore_changes = [final_snapshot_identifier]
  }
}
```

**`outputs.tf`**:

```hcl
output "rds_endpoint"              { value = aws_db_instance.this.address }
output "rds_port"                  { value = aws_db_instance.this.port }
output "db_name"                   { value = aws_db_instance.this.db_name }
output "master_username"           { value = aws_db_instance.this.username }
output "master_password_secret_arn" {
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
  description = "Secret contains {username,password} for the master user"
}
output "kms_key_arn"               { value = aws_kms_key.rds.arn }
output "security_group_id"         { value = aws_security_group.rds.id }
```

## Connect and verify

```bash
# 1. Retrieve the password
export PGPASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id "$(terraform output -raw master_password_secret_arn)" \
  --query SecretString --output text | jq -r .password)

# 2. Connect
psql "host=$(terraform output -raw rds_endpoint) \
      port=5432 dbname=appdb user=appadmin sslmode=require"
```

Once in:

```sql
-- Are we really on RDS?
SELECT current_setting('rds.superuser_reserved_connections', true);
SELECT * FROM pg_extension;

-- The recommended baseline extensions
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Prove parameter group values took effect
SHOW shared_preload_libraries;
SHOW log_min_duration_statement;
SHOW rds.force_ssl;

-- Prove SSL is in effect
SELECT ssl, version, cipher FROM pg_stat_ssl WHERE pid = pg_backend_pid();
```

### Turn on IAM auth for a user

```sql
CREATE ROLE svc_iam LOGIN;
GRANT rds_iam TO svc_iam;
```

Then from the client:

```bash
export TOKEN=$(aws rds generate-db-auth-token \
  --hostname "$(terraform output -raw rds_endpoint)" \
  --port 5432 --username svc_iam --region "$AWS_REGION")

PGPASSWORD="$TOKEN" psql "host=$(terraform output -raw rds_endpoint) \
  port=5432 dbname=appdb user=svc_iam sslmode=require"
```

No stored password. Rotate by rotating the IAM permission.

## Day-2 essentials on RDS

- **Parameter changes**: some are `pending-reboot`, some are dynamic. `terraform apply` won't reboot; set `apply_immediately = true` on the DB instance during a maintenance window if needed.
- **Version upgrades**: `engine_version` change → in-place upgrade. Prefer minor auto; do majors deliberately on a snapshot restore.
- **Read replicas** (day 22): `aws_db_instance` with `replicate_source_db = aws_db_instance.this.identifier`.
- **Blue/Green Deployments**: RDS-managed shadow environment for zero-downtime changes.
- **Storage autoscaling**: `max_allocated_storage` in the module.

## Cleanup

```bash
# Optional: disable deletion protection first
terraform apply -var deletion_protection=false -auto-approve
terraform destroy -auto-approve
```

## Worksheet

1. In your Terraform code, which single argument would you flip to make the module produce a **Multi-AZ** instance and roughly what does that cost you (order of magnitude)?  
   _Answer:_ …

2. Add a second parameter to the parameter group: enable `pgaudit` for `write, ddl`. Show the two resource changes (parameter group + `shared_preload_libraries`) needed.  
   _Answer:_ …

3. Which of these belongs in `apply_immediately = true` and why?  
   `instance_class` change; `parameter_group_name` change with static params; `backup_retention_period` change; adding a security group.  
   _Answer:_ …

4. Rewrite the module so the master password is NOT AWS-managed but comes from an already-existing Secrets Manager secret you own. Sketch the diff.  
   _Answer:_ …

5. Bonus: describe the failure mode if you forget `rds.force_ssl = 1`. Give one CloudWatch metric or log event that would surface it.  
   _Answer:_ …

## References

- AWS provider `aws_db_instance`: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_instance
- RDS user guide: https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_PostgreSQL.html
- Managed master user password: https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-secrets-manager.html
- IAM database auth: https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.IAMDBAuth.html
