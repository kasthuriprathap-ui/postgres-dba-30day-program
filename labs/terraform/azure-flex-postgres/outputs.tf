output "server_name" {
  value = azurerm_postgresql_flexible_server.this.name
}

output "fqdn" {
  description = "Fully qualified DNS name to connect to"
  value       = azurerm_postgresql_flexible_server.this.fqdn
}

output "admin_username" {
  value = azurerm_postgresql_flexible_server.this.administrator_login
}

output "admin_password" {
  description = "Server admin password. Move to Key Vault for production (see README)."
  value       = random_password.admin.result
  sensitive   = true
}

output "resource_group_name" {
  value = local.rg_name
}

output "server_id" {
  value = azurerm_postgresql_flexible_server.this.id
}

output "delegated_subnet_id" {
  value = local.delegated_subnet_id
}

output "private_dns_zone_id" {
  value = local.private_dns_zone_id
}

output "psql_command" {
  description = "Reachable only from inside the VNet"
  value = "psql \"host=${azurerm_postgresql_flexible_server.this.fqdn} port=5432 dbname=postgres user=${azurerm_postgresql_flexible_server.this.administrator_login} sslmode=require\""
}
