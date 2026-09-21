variable "name" {
  description = "Name prefix for all resources (3-24 chars, lowercase, hyphens ok)"
  type        = string
  default     = "pgdba-lab"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,23}$", var.name))
    error_message = "name must be 3-24 chars, lowercase letters/digits/hyphens, starting with a letter."
  }
}

variable "location" {
  description = "Azure region (e.g., eastus, westus3, westeurope)"
  type        = string
  default     = "eastus"
}

variable "resource_group_name" {
  description = "Existing resource group. If empty, a new one is created."
  type        = string
  default     = ""
}

variable "vnet_address_space" {
  description = "Address space for the new VNet (only used if create_network = true)"
  type        = list(string)
  default     = ["10.30.0.0/16"]
}

variable "subnet_address_prefix" {
  description = "CIDR for the delegated subnet the Flexible Server sits in"
  type        = string
  default     = "10.30.1.0/24"
}

variable "create_network" {
  description = "When true, create VNet + delegated subnet + private DNS zone here. Set false and provide *_id vars to reuse existing infra."
  type        = bool
  default     = true
}

variable "existing_vnet_id" {
  description = "Full resource ID of an existing VNet (used when create_network = false)"
  type        = string
  default     = ""
}

variable "existing_delegated_subnet_id" {
  description = "Full resource ID of a subnet ALREADY delegated to Microsoft.DBforPostgreSQL/flexibleServers"
  type        = string
  default     = ""
}

variable "existing_private_dns_zone_id" {
  description = "Full resource ID of an existing privatelink.postgres.database.azure.com DNS zone"
  type        = string
  default     = ""
}

variable "sku_name" {
  description = "Server tier + size. See https://learn.microsoft.com/azure/postgresql/flexible-server/concepts-compute-storage"
  type        = string
  default     = "GP_Standard_D2ds_v5"
}

variable "storage_mb" {
  description = "Storage size in MiB (32768 = 32 GiB is the minimum)"
  type        = number
  default     = 32768
}

variable "storage_tier" {
  description = "Storage tier: P4, P6, P10, P15, P20, P30, P40, P50, P60, P70, P80"
  type        = string
  default     = "P10"
}

variable "postgresql_version" {
  description = "Major version: 11, 12, 13, 14, 15, 16"
  type        = string
  default     = "16"
}

variable "admin_username" {
  description = "Server admin login"
  type        = string
  default     = "pgadmin"
}

variable "backup_retention_days" {
  description = "Backup retention (7-35)"
  type        = number
  default     = 14
}

variable "geo_redundant_backup" {
  description = "Enable geo-redundant backup"
  type        = bool
  default     = false
}

variable "high_availability_mode" {
  description = "\"Disabled\", \"SameZone\", or \"ZoneRedundant\". HA is not supported on Burstable-tier SKUs."
  type        = string
  default     = "Disabled"

  validation {
    condition     = contains(["Disabled", "SameZone", "ZoneRedundant"], var.high_availability_mode)
    error_message = "high_availability_mode must be one of Disabled, SameZone, ZoneRedundant."
  }
}

variable "standby_availability_zone" {
  description = "Standby AZ for HA (e.g., \"2\"). Ignored when HA is Disabled."
  type        = string
  default     = "2"
}

variable "azure_ad_auth_enabled" {
  description = "Enable Microsoft Entra ID (Azure AD) authentication"
  type        = bool
  default     = true
}

variable "password_auth_enabled" {
  description = "Enable password authentication"
  type        = bool
  default     = true
}

variable "tenant_id" {
  description = "Entra tenant ID (required when azure_ad_auth_enabled = true)"
  type        = string
  default     = ""
}

variable "enabled_extensions" {
  description = "Value for the azure.extensions server parameter (comma-separated)"
  type        = string
  default     = "PG_STAT_STATEMENTS,PGCRYPTO,PGVECTOR,PG_CRON"
}

variable "maintenance_window" {
  description = "Custom maintenance window. Day 0-6 = Sun-Sat; UTC hour/minute."
  type = object({
    day_of_week  = number
    start_hour   = number
    start_minute = number
  })
  default = {
    day_of_week  = 0 # Sunday
    start_hour   = 4
    start_minute = 0
  }
}

variable "tags" {
  description = "Extra tags to apply"
  type        = map(string)
  default = {
    Project = "pgdba-30day-program"
    Lab     = "azure-flex-postgres"
  }
}
