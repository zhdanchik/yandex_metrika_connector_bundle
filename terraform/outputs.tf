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
# В DataLens нет deep-link «создать воркбук и сразу импорт JSON
# в него»: /workbooks/import требует уже существующий workbookId.
# Поэтому отдаём ссылку на список коллекций — пользователь сам:
#   1. создаёт/выбирает коллекцию,
#   2. создаёт пустой воркбук,
#   3. внутри воркбука → «⋯» → «Импортировать» → datalens/dashboard.json.
# Connection к ClickHouse также создаётся руками (TF-провайдер пока
# не умеет yandex_datalens_connection для CH — см. datalens/NOTES.md).
# Полный рецепт — datalens/BUILD_SPEC.md §§1-2, troubleshooting — README.
# ──────────────────────────────────────────────────────────────

output "datalens_import_url" {
  description = <<-EOT
    Ссылка на список коллекций DataLens. Далее:
      1. Создай/выбери коллекцию.
      2. Создай в ней пустой воркбук.
      3. Внутри воркбука → «⋯» → «Импортировать» → datalens/dashboard.json.
      4. На шаге привязки connection укажи clickhouse_cluster_id.
    Пошагово — в datalens/BUILD_SPEC.md.
  EOT
  value       = "https://datalens.yandex.cloud/collections"
}
