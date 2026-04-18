output "clickhouse_host" {
  description = "FQDN хоста ClickHouse"
  value       = module.clickhouse.host
}

output "clickhouse_cluster_id" {
  description = "ID кластера Managed ClickHouse"
  value       = module.clickhouse.cluster_id
}

output "clickhouse_db_name" {
  description = "Имя базы данных ClickHouse"
  value       = module.clickhouse.db_name
}

output "clickhouse_db_user" {
  description = "Имя пользователя ClickHouse"
  value       = module.clickhouse.db_user
}

output "function_id" {
  description = "ID Cloud Function трансформации"
  value       = module.function.function_id
}

output "lockbox_secret_id" {
  description = "ID Lockbox-секрета (для ручной проверки payload)"
  value       = module.lockbox.secret_id
}

output "transfer_id" {
  description = "ID Data Transfer трансфера"
  value       = module.transfer.transfer_id
}

output "trigger_id" {
  description = "ID триггера Cloud Scheduler"
  value       = module.scheduler.trigger_id
}
