output "rds_endpoint" {
  description = "DNS endpoint of the RDS instance"
  value       = aws_db_instance.this.address
}

output "rds_port" {
  description = "Listening port"
  value       = aws_db_instance.this.port
}

output "rds_arn" {
  description = "ARN of the DB instance"
  value       = aws_db_instance.this.arn
}

output "db_name" {
  value = aws_db_instance.this.db_name
}

output "master_username" {
  value = aws_db_instance.this.username
}

output "master_password_secret_arn" {
  description = "Secrets Manager ARN. SecretString is JSON: {\"username\":\"...\",\"password\":\"...\"}"
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "security_group_id" {
  value = aws_security_group.rds.id
}

output "kms_key_arn" {
  value = aws_kms_key.rds.arn
}

output "parameter_group_name" {
  value = aws_db_parameter_group.this.name
}

output "psql_command" {
  description = "Ready-to-copy psql command (still needs the password)"
  value       = "psql \"host=${aws_db_instance.this.address} port=${aws_db_instance.this.port} dbname=${aws_db_instance.this.db_name} user=${aws_db_instance.this.username} sslmode=require\""
}
