output "cluster_id" {
  description = "ID кластера Managed ClickHouse"
  value       = yandex_mdb_clickhouse_cluster.main.id
}

output "host" {
  description = "FQDN хоста ClickHouse — передаётся в Cloud Function как CLICKHOUSE_HOST"
  value       = local.host
}

output "db_name" {
  description = "Имя базы данных"
  value       = var.db_name
}

output "db_user" {
  description = "Имя пользователя"
  value       = var.db_user
}
