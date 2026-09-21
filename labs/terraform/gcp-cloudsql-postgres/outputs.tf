output "instance_name" {
  value = google_sql_database_instance.this.name
}

output "connection_name" {
  description = "PROJECT:REGION:INSTANCE — feed this to the Cloud SQL Auth Proxy"
  value       = google_sql_database_instance.this.connection_name
}

output "private_ip" {
  description = "Private IP reachable from inside the VPC"
  value       = google_sql_database_instance.this.private_ip_address
}

output "db_name" {
  value = google_sql_database.appdb.name
}

output "admin_user" {
  value = google_sql_user.postgres.name
}

output "admin_password" {
  description = "Password for the built-in `postgres` user. In production, rotate and store in Secret Manager."
  value       = random_password.postgres.result
  sensitive   = true
}

output "auth_proxy_command" {
  description = "Start the Cloud SQL Auth Proxy on 127.0.0.1:5432"
  value       = "cloud-sql-proxy ${google_sql_database_instance.this.connection_name}"
}

output "psql_via_proxy_command" {
  description = "Connect once the Auth Proxy is running"
  value       = "psql \"host=127.0.0.1 port=5432 dbname=${google_sql_database.appdb.name} user=${google_sql_user.postgres.name} sslmode=disable\""
}
