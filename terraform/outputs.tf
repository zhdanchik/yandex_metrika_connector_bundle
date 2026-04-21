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

# ──────────────────────────────────────────────────────────────
# DataLens: ссылка на импорт готового дашборда.
# Connection к ClickHouse создаётся пользователем руками в UI
# (провайдер пока не поддерживает CH в yandex_datalens_connection).
# См. datalens/BUILD_SPEC.md и раздел «DataLens dashboard» в README.
# ──────────────────────────────────────────────────────────────

output "datalens_import_url" {
  description = <<-EOT
    Deep-link для импорта datalens/dashboard.json в DataLens.
    Открой URL, выбери файл dashboard.json, затем на шаге привязки
    подключения укажи ClickHouse-кластер (cluster_id из clickhouse_cluster_id).
  EOT
  value       = "https://datalens.yandex.cloud/workbooks/import?folderId=${var.folder_id}"
}
