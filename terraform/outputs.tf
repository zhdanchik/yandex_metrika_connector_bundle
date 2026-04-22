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
# DataLens: точка входа для импорта готового дашборда.
# Deep-link «создать воркбук прямо из JSON» отсутствует — endpoint
# /workbooks/import требует существующий workbookId. Зато в диалоге
# «Создать воркбук» (в UI коллекции) есть поле «Импорт из файла»,
# которое делает ровно то, что нам нужно, одним шагом.
# Connection к ClickHouse также создаётся руками (TF-провайдер пока
# не умеет yandex_datalens_connection для CH — см. datalens/NOTES.md).
# Полный рецепт — datalens/BUILD_SPEC.md §§1-2, troubleshooting — README.
# ──────────────────────────────────────────────────────────────

output "datalens_import_url" {
  description = <<-EOT
    Ссылка на список коллекций DataLens. Далее:
      1. Создай/выбери коллекцию.
      2. Жми «Создать → Воркбук». В диалоге укажи «Импорт из файла»
         и выбери datalens/dashboard.json → «Создать».
      3. На шаге привязки connection укажи clickhouse_cluster_id.
    Пошагово — в datalens/BUILD_SPEC.md.
  EOT
  value       = "https://datalens.yandex.cloud/collections"
}
