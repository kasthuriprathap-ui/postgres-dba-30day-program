########################################
# KMS key (customer-managed) for RDS encryption
########################################

resource "aws_kms_key" "rds" {
  description             = "KMS key for RDS PostgreSQL: ${var.name}"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_kms_alias" "rds" {
  name          = "alias/${var.name}-rds"
  target_key_id = aws_kms_key.rds.key_id
}

########################################
# Networking: subnet group + security group
########################################

resource "aws_db_subnet_group" "this" {
  name        = "${var.name}-subnets"
  description = "Subnet group for ${var.name}"
  subnet_ids  = var.subnet_ids
}

resource "aws_security_group" "rds" {
  name        = "${var.name}-rds-sg"
  description = "PostgreSQL access to ${var.name}"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "pg_from_cidrs" {
  for_each          = toset(var.allowed_cidrs)
  security_group_id = aws_security_group.rds.id
  ip_protocol       = "tcp"
  from_port         = 5432
  to_port           = 5432
  cidr_ipv4         = each.value
  description       = "PostgreSQL from ${each.value}"
}

resource "aws_vpc_security_group_ingress_rule" "pg_from_sgs" {
  for_each                     = toset(var.allowed_security_group_ids)
  security_group_id            = aws_security_group.rds.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = each.value
  description                  = "PostgreSQL from ${each.value}"
}

resource "aws_vpc_security_group_egress_rule" "all_out" {
  security_group_id = aws_security_group.rds.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "All outbound"
}

########################################
# Parameter group (postgresql.conf on RDS)
########################################

locals {
  major_version = split(".", var.engine_version)[0]
  pg_family     = "postgres${local.major_version}"
}

resource "aws_db_parameter_group" "this" {
  name        = "${var.name}-${local.pg_family}"
  family      = local.pg_family
  description = "Managed by Terraform (Day 15 lab)"

  # -------- observability --------
  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements,auto_explain"
    apply_method = "pending-reboot"
  }
  parameter {
    name  = "pg_stat_statements.track"
    value = "ALL"
  }
  parameter {
    name  = "pg_stat_statements.max"
    value = "10000"
  }
  parameter {
    name  = "track_activity_query_size"
    value = "4096"
  }
  parameter {
    name  = "log_min_duration_statement"
    value = "500"
  }
  parameter {
    name  = "auto_explain.log_min_duration"
    value = "500"
  }
  parameter {
    name  = "auto_explain.log_analyze"
    value = "1"
  }
  parameter {
    name  = "auto_explain.log_buffers"
    value = "1"
  }
  parameter {
    name  = "auto_explain.log_verbose"
    value = "1"
  }
  parameter {
    name  = "auto_explain.log_format"
    value = "json"
  }
  parameter {
    name  = "log_connections"
    value = "1"
  }
  parameter {
    name  = "log_disconnections"
    value = "1"
  }
  parameter {
    name  = "log_lock_waits"
    value = "1"
  }
  parameter {
    name  = "log_temp_files"
    value = "0"
  }
  parameter {
    name  = "log_checkpoints"
    value = "1"
  }

  # -------- guardrails --------
  parameter {
    name  = "idle_in_transaction_session_timeout"
    value = "600000" # 10 min in ms
  }
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
}

########################################
# IAM role for RDS Enhanced Monitoring
########################################

data "aws_iam_policy_document" "monitoring_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "rds_monitoring" {
  name               = "${var.name}-rds-monitoring"
  assume_role_policy = data.aws_iam_policy_document.monitoring_assume.json
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

########################################
# The DB instance
########################################

resource "aws_db_instance" "this" {
  identifier     = var.name
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = var.storage_type
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.rds.arn

  db_name  = var.db_name
  username = var.master_username

  # Let RDS manage the master password and store it in Secrets Manager.
  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.rds.arn

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.this.name

  multi_az                            = var.multi_az
  publicly_accessible                 = false
  iam_database_authentication_enabled = true

  backup_retention_period  = var.backup_retention_days
  backup_window            = var.backup_window
  maintenance_window       = var.maintenance_window
  copy_tags_to_snapshot    = true
  delete_automated_backups = false
  deletion_protection      = var.deletion_protection

  performance_insights_enabled          = true
  performance_insights_kms_key_id       = aws_kms_key.rds.arn
  performance_insights_retention_period = var.performance_insights_retention_days
  monitoring_interval                   = var.monitoring_interval_seconds
  monitoring_role_arn                   = aws_iam_role.rds_monitoring.arn

  enabled_cloudwatch_logs_exports = var.log_exports

  auto_minor_version_upgrade = var.auto_minor_version_upgrade
  apply_immediately          = false

  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.name}-final-${formatdate("YYYYMMDDhhmm", timestamp())}"

  lifecycle {
    ignore_changes = [
      final_snapshot_identifier,
      # RDS may bump minor engine_version during maintenance
      engine_version,
    ]
  }
}
