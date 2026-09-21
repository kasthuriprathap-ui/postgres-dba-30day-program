########################################
# Resource group (create or reuse)
########################################

resource "azurerm_resource_group" "pg" {
  count    = var.resource_group_name == "" ? 1 : 0
  name     = "rg-${var.name}"
  location = var.location
  tags     = var.tags
}

data "azurerm_resource_group" "existing" {
  count = var.resource_group_name != "" ? 1 : 0
  name  = var.resource_group_name
}

locals {
  rg_name     = var.resource_group_name != "" ? data.azurerm_resource_group.existing[0].name     : azurerm_resource_group.pg[0].name
  rg_location = var.resource_group_name != "" ? data.azurerm_resource_group.existing[0].location : azurerm_resource_group.pg[0].location
}

########################################
# Network — VNet + delegated subnet + private DNS zone
# (only created when create_network = true)
########################################

resource "azurerm_virtual_network" "pg" {
  count               = var.create_network ? 1 : 0
  name                = "vnet-${var.name}"
  resource_group_name = local.rg_name
  location            = local.rg_location
  address_space       = var.vnet_address_space
  tags                = var.tags
}

resource "azurerm_subnet" "pg" {
  count                = var.create_network ? 1 : 0
  name                 = "snet-${var.name}-pg"
  resource_group_name  = local.rg_name
  virtual_network_name = azurerm_virtual_network.pg[0].name
  address_prefixes     = [var.subnet_address_prefix]

  # REQUIRED: Flexible Server needs the subnet delegated to it.
  delegation {
    name = "pg-flex-delegation"
    service_delegation {
      name = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
      ]
    }
  }
}

resource "azurerm_private_dns_zone" "pg" {
  count               = var.create_network ? 1 : 0
  name                = "${var.name}.private.postgres.database.azure.com"
  resource_group_name = local.rg_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "pg" {
  count                 = var.create_network ? 1 : 0
  name                  = "pdz-link-${var.name}"
  resource_group_name   = local.rg_name
  private_dns_zone_name = azurerm_private_dns_zone.pg[0].name
  virtual_network_id    = azurerm_virtual_network.pg[0].id
  tags                  = var.tags
}

locals {
  delegated_subnet_id  = var.create_network ? azurerm_subnet.pg[0].id           : var.existing_delegated_subnet_id
  private_dns_zone_id  = var.create_network ? azurerm_private_dns_zone.pg[0].id : var.existing_private_dns_zone_id
}

########################################
# Admin password (kept in Terraform state — see README for Key Vault alt)
########################################

resource "random_password" "admin" {
  length      = 24
  special     = true
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
  min_special = 2
  # Flexible Server rejects a handful of characters in the admin password.
  override_special = "!@#$%*_+-="
}

########################################
# Flexible Server
########################################

resource "azurerm_postgresql_flexible_server" "this" {
  name                = "${var.name}-pg"
  resource_group_name = local.rg_name
  location            = local.rg_location

  version    = var.postgresql_version
  sku_name   = var.sku_name
  storage_mb = var.storage_mb
  storage_tier = var.storage_tier

  administrator_login    = var.admin_username
  administrator_password = random_password.admin.result

  delegated_subnet_id = local.delegated_subnet_id
  private_dns_zone_id = local.private_dns_zone_id
  public_network_access_enabled = false

  backup_retention_days        = var.backup_retention_days
  geo_redundant_backup_enabled = var.geo_redundant_backup

  dynamic "high_availability" {
    for_each = var.high_availability_mode == "Disabled" ? [] : [1]
    content {
      mode                      = var.high_availability_mode
      standby_availability_zone = var.high_availability_mode == "ZoneRedundant" ? var.standby_availability_zone : null
    }
  }

  authentication {
    active_directory_auth_enabled = var.azure_ad_auth_enabled
    password_auth_enabled         = var.password_auth_enabled
    tenant_id                     = var.azure_ad_auth_enabled ? var.tenant_id : null
  }

  maintenance_window {
    day_of_week  = var.maintenance_window.day_of_week
    start_hour   = var.maintenance_window.start_hour
    start_minute = var.maintenance_window.start_minute
  }

  tags = var.tags

  lifecycle {
    ignore_changes = [
      zone, # allow HA failovers to swap primary AZ without churn
    ]
  }

  depends_on = [
    azurerm_private_dns_zone_virtual_network_link.pg,
  ]
}

########################################
# Server parameters (postgresql.conf equivalents)
########################################

resource "azurerm_postgresql_flexible_server_configuration" "preload" {
  name      = "shared_preload_libraries"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "pg_stat_statements,auto_explain,pgaudit"
}

resource "azurerm_postgresql_flexible_server_configuration" "extensions" {
  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = var.enabled_extensions
}

resource "azurerm_postgresql_flexible_server_configuration" "log_min_duration" {
  name      = "log_min_duration_statement"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "500"
}

resource "azurerm_postgresql_flexible_server_configuration" "log_connections" {
  name      = "log_connections"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "on"
}

resource "azurerm_postgresql_flexible_server_configuration" "log_disconnections" {
  name      = "log_disconnections"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "on"
}

resource "azurerm_postgresql_flexible_server_configuration" "log_lock_waits" {
  name      = "log_lock_waits"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "on"
}

resource "azurerm_postgresql_flexible_server_configuration" "idle_in_txn_timeout" {
  name      = "idle_in_transaction_session_timeout"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "600000" # 10 min in ms
}

resource "azurerm_postgresql_flexible_server_configuration" "pg_stat_statements_track" {
  name      = "pg_stat_statements.track"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "ALL"
}

resource "azurerm_postgresql_flexible_server_configuration" "pgaudit_log" {
  name      = "pgaudit.log"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "DDL,ROLE,WRITE"
}
