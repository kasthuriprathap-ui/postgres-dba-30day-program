variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region, e.g. us-central1, europe-west1"
  type        = string
  default     = "us-central1"
}

variable "name" {
  description = "Name prefix for the instance and children"
  type        = string
  default     = "pgdba-lab"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,30}$", var.name))
    error_message = "name must be 3-31 chars, lowercase letters/digits/hyphens, starting with a letter."
  }
}

variable "network_id" {
  description = "Self-link of the VPC network (projects/<p>/global/networks/<n>). Required for private IP."
  type        = string
}

variable "create_private_service_access" {
  description = "Provision the /24 IP range + Service Networking peering needed for Cloud SQL private IP. Set false if it's already done in the target VPC."
  type        = bool
  default     = true
}

variable "private_service_access_prefix_length" {
  description = "Prefix length of the allocated range for Google-managed services (16-24)"
  type        = number
  default     = 20
}

variable "database_version" {
  description = "e.g. POSTGRES_16, POSTGRES_15"
  type        = string
  default     = "POSTGRES_16"
}

variable "edition" {
  description = "ENTERPRISE (classic) or ENTERPRISE_PLUS"
  type        = string
  default     = "ENTERPRISE"

  validation {
    condition     = contains(["ENTERPRISE", "ENTERPRISE_PLUS"], var.edition)
    error_message = "edition must be ENTERPRISE or ENTERPRISE_PLUS."
  }
}

variable "tier" {
  description = "Machine tier, e.g. db-custom-2-4096, db-perf-optimized-N-2, db-f1-micro (sandbox only)"
  type        = string
  default     = "db-custom-2-4096"
}

variable "availability_type" {
  description = "ZONAL (single-zone) or REGIONAL (HA with sync standby)"
  type        = string
  default     = "REGIONAL"

  validation {
    condition     = contains(["ZONAL", "REGIONAL"], var.availability_type)
    error_message = "availability_type must be ZONAL or REGIONAL."
  }
}

variable "disk_type" {
  description = "PD_SSD or PD_HDD"
  type        = string
  default     = "PD_SSD"
}

variable "disk_size_gb" {
  description = "Initial disk size"
  type        = number
  default     = 20
}

variable "disk_autoresize" {
  description = "Grow disk automatically as needed"
  type        = bool
  default     = true
}

variable "disk_autoresize_limit_gb" {
  description = "0 = no limit"
  type        = number
  default     = 200
}

variable "db_name" {
  description = "Initial application database"
  type        = string
  default     = "appdb"
}

variable "backup_retention_days" {
  description = "Retention (via retained_backups count)"
  type        = number
  default     = 14
}

variable "point_in_time_recovery" {
  description = "Enable PITR (WAL retention on backups)"
  type        = bool
  default     = true
}

variable "transaction_log_retention_days" {
  description = "WAL retention window for PITR (1-35)"
  type        = number
  default     = 7
}

variable "require_ssl" {
  description = "Reject non-SSL connections"
  type        = bool
  default     = true
}

variable "iam_authentication" {
  description = "Enable Cloud IAM database authentication"
  type        = bool
  default     = true
}

variable "iam_members" {
  description = "IAM principals (users, groups, service accounts) to add as Cloud SQL DB users with instanceUser role"
  type = list(object({
    email = string
    type  = string # user, group, serviceAccount
  }))
  default = []
}

variable "maintenance_window" {
  description = "day: 1-7 (Mon-Sun in GCP semantics), hour: 0-23 UTC, update_track: canary or stable"
  type = object({
    day          = number
    hour         = number
    update_track = string
  })
  default = {
    day          = 7 # Sunday
    hour         = 4
    update_track = "stable"
  }
}

variable "deletion_protection" {
  description = "Terraform-side + API-side deletion protection"
  type        = bool
  default     = true
}

variable "labels" {
  description = "Labels applied to the instance"
  type        = map(string)
  default = {
    project = "pgdba-30day-program"
    lab     = "gcp-cloudsql-postgres"
  }
}
