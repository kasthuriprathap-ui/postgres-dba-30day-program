########################################
# Private Service Access
# Cloud SQL private IP works via VPC peering with Google-managed services.
# It requires a reserved global IP range in your VPC + a service networking
# connection. Skip these two resources if the peering already exists.
########################################

resource "google_compute_global_address" "private_service_access" {
  count         = var.create_private_service_access ? 1 : 0
  name          = "${var.name}-psa-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = var.private_service_access_prefix_length
  network       = var.network_id
}

resource "google_service_networking_connection" "private_service_access" {
  count                   = var.create_private_service_access ? 1 : 0
  network                 = var.network_id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_service_access[0].name]
}

########################################
# Random admin password
########################################

resource "random_password" "postgres" {
  length      = 24
  special     = true
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
  min_special = 2
}

########################################
# The Cloud SQL instance
########################################

resource "google_sql_database_instance" "this" {
  name             = "${var.name}-pg"
  region           = var.region
  database_version = var.database_version
  deletion_protection = var.deletion_protection

  settings {
    tier              = var.tier
    edition           = var.edition
    availability_type = var.availability_type
    disk_type         = var.disk_type
    disk_size         = var.disk_size_gb
    disk_autoresize   = var.disk_autoresize
    disk_autoresize_limit = var.disk_autoresize_limit_gb

    deletion_protection_enabled = var.deletion_protection
    user_labels                 = var.labels

    ip_configuration {
      ipv4_enabled    = false           # no public IP
      private_network = var.network_id
      require_ssl     = var.require_ssl
    }

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = var.point_in_time_recovery
      start_time                     = "03:00"
      transaction_log_retention_days = var.transaction_log_retention_days
      location                       = var.region

      backup_retention_settings {
        retained_backups = var.backup_retention_days
        retention_unit   = "COUNT"
      }
    }

    maintenance_window {
      day          = var.maintenance_window.day
      hour         = var.maintenance_window.hour
      update_track = var.maintenance_window.update_track
    }

    insights_config {
      query_insights_enabled  = true
      record_application_tags = true
      record_client_address   = true
      query_string_length     = 4096
    }

    # -------- Database flags (Cloud SQL's postgresql.conf) --------
    # Note: shared_preload_libraries is not directly settable on Cloud SQL;
    # use the cloudsql.enable_* flags below to opt in to preloaded extensions.
    database_flags {
      name  = "cloudsql.iam_authentication"
      value = var.iam_authentication ? "on" : "off"
    }
    database_flags {
      name  = "cloudsql.enable_pgaudit"
      value = "on"
    }
    database_flags {
      name  = "cloudsql.enable_pg_cron"
      value = "on"
    }
    database_flags {
      name  = "pg_stat_statements.track"
      value = "ALL"
    }
    database_flags {
      name  = "pg_stat_statements.max"
      value = "10000"
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
    database_flags {
      name  = "log_lock_waits"
      value = "on"
    }
    database_flags {
      name  = "log_checkpoints"
      value = "on"
    }
    database_flags {
      name  = "idle_in_transaction_session_timeout"
      value = "600000"
    }
  }

  depends_on = [
    google_service_networking_connection.private_service_access,
  ]
}

########################################
# Initial database + admin user
########################################

resource "google_sql_database" "appdb" {
  name     = var.db_name
  instance = google_sql_database_instance.this.name
}

resource "google_sql_user" "postgres" {
  name     = "postgres"
  instance = google_sql_database_instance.this.name
  password = random_password.postgres.result
}

########################################
# IAM DB users (optional)
#   For each IAM principal provided, create a Cloud SQL user of the
#   matching type and grant them the instanceUser role at the project.
########################################

resource "google_sql_user" "iam" {
  for_each = { for m in var.iam_members : m.email => m }
  name     = each.value.email
  instance = google_sql_database_instance.this.name
  type = (
    each.value.type == "serviceAccount" ? "CLOUD_IAM_SERVICE_ACCOUNT" :
    each.value.type == "group"          ? "CLOUD_IAM_GROUP"           :
    "CLOUD_IAM_USER"
  )
}

resource "google_project_iam_member" "instance_user" {
  for_each = { for m in var.iam_members : m.email => m }
  project  = var.project_id
  role     = "roles/cloudsql.instanceUser"
  member   = "${each.value.type}:${each.value.email}"
}
