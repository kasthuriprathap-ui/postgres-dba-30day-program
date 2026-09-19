variable "region" {
  description = "AWS region to deploy into"
  type        = string
}

variable "name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "pgdba-lab"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,30}$", var.name))
    error_message = "name must be 3-31 chars, lowercase letters/digits/hyphens, starting with a letter."
  }
}

variable "vpc_id" {
  description = "VPC in which to create the RDS instance"
  type        = string
}

variable "subnet_ids" {
  description = "At least two subnet IDs in different AZs (private subnets recommended)"
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "Provide at least two subnet IDs across distinct AZs."
  }
}

variable "allowed_cidrs" {
  description = "CIDR blocks allowed to reach TCP 5432"
  type        = list(string)
  default     = []
}

variable "allowed_security_group_ids" {
  description = "Additional security groups allowed to reach TCP 5432 (e.g., your app SG)"
  type        = list(string)
  default     = []
}

variable "instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "Initial storage (GiB)"
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = "Autoscaling ceiling for storage (GiB)"
  type        = number
  default     = 100
}

variable "storage_type" {
  description = "gp3 recommended"
  type        = string
  default     = "gp3"
}

variable "multi_az" {
  description = "Enable synchronous standby in a second AZ"
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  description = "0 disables automated backups; use >= 7 in production"
  type        = number
  default     = 7
}

variable "engine_version" {
  description = "PostgreSQL engine version (major.minor)"
  type        = string
  default     = "16.3"
}

variable "db_name" {
  description = "Initial database name"
  type        = string
  default     = "appdb"
}

variable "master_username" {
  description = "Master role login name"
  type        = string
  default     = "appadmin"
}

variable "deletion_protection" {
  description = "Block accidental terraform destroy"
  type        = bool
  default     = true
}

variable "performance_insights_retention_days" {
  description = "7 = free tier"
  type        = number
  default     = 7
}

variable "monitoring_interval_seconds" {
  description = "Enhanced Monitoring cadence (0, 1, 5, 10, 15, 30, 60)"
  type        = number
  default     = 30
}

variable "log_exports" {
  description = "CloudWatch log types to export"
  type        = list(string)
  default     = ["postgresql", "upgrade"]
}

variable "auto_minor_version_upgrade" {
  description = "Let RDS apply minor patches in maintenance windows"
  type        = bool
  default     = true
}

variable "backup_window" {
  description = "Automated backup window (UTC)"
  type        = string
  default     = "03:00-04:00"
}

variable "maintenance_window" {
  description = "Maintenance window (UTC)"
  type        = string
  default     = "sun:04:30-sun:05:30"
}

variable "tags" {
  description = "Extra tags to merge in"
  type        = map(string)
  default     = {}
}
