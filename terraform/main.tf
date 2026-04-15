provider "yandex" {
  folder_id = var.folder_id
}

locals {
  prefix = var.name
}

# ══════════════════════════════════════════════════════════════
# Service accounts
#
# Создаются здесь, а не внутри модулей, чтобы разорвать
# циклическую зависимость: lockbox нужны ID этих SA для IAM-
# биндингов, а function/transfer нужен secret_id из lockbox.
# ══════════════════════════════════════════════════════════════

resource "yandex_iam_service_account" "function" {
  name      = "${local.prefix}-function-sa"
  folder_id = var.folder_id
}

resource "yandex_iam_service_account" "transfer" {
  name      = "${local.prefix}-transfer-sa"
  folder_id = var.folder_id
}

# Функция вызывает саму себя через триггер.
resource "yandex_resourcemanager_folder_iam_member" "function_invoker" {
  folder_id = var.folder_id
  role      = "serverless.functions.invoker"
  member    = "serviceAccount:${yandex_iam_service_account.function.id}"
}

# ══════════════════════════════════════════════════════════════
# Lockbox: секрет с паролем CH и OAuth-токеном Метрики
# ══════════════════════════════════════════════════════════════

module "lockbox" {
  source = "./modules/lockbox"

  name                = "${local.prefix}-secrets"
  folder_id           = var.folder_id
  clickhouse_password = var.clickhouse_password
  metrika_oauth_token = var.metrika_oauth_token
  function_sa_id      = yandex_iam_service_account.function.id
  transfer_sa_id      = yandex_iam_service_account.transfer.id
}

# ══════════════════════════════════════════════════════════════
# Managed ClickHouse: кластер + схема БД
# ══════════════════════════════════════════════════════════════

module "clickhouse" {
  source = "./modules/clickhouse"

  name                = "${local.prefix}-ch"
  folder_id           = var.folder_id
  network_id          = var.network_id
  subnet_id           = var.subnet_id
  zone                = var.zone
  clickhouse_password = var.clickhouse_password
}

# ══════════════════════════════════════════════════════════════
# Cloud Function: трансформация пайплайна
# ══════════════════════════════════════════════════════════════

module "function" {
  source = "./modules/function"

  name               = "${local.prefix}-transform"
  folder_id          = var.folder_id
  service_account_id = yandex_iam_service_account.function.id
  bucket_name        = var.function_bucket_name
  network_id         = var.network_id

  lockbox_secret_id = module.lockbox.secret_id
  clickhouse_host   = module.clickhouse.host
  clickhouse_db     = module.clickhouse.db_name
  clickhouse_user   = module.clickhouse.db_user

  counter_id     = var.counter_id
  goal_id        = var.goal_id
  half_life_days = var.half_life_days
}

# ══════════════════════════════════════════════════════════════
# Data Transfer: Яндекс Метрика → ClickHouse
# ══════════════════════════════════════════════════════════════

module "transfer" {
  source = "./modules/transfer"

  name               = "${local.prefix}-metrika"
  folder_id          = var.folder_id
  service_account_id = yandex_iam_service_account.transfer.id
  counter_id         = var.counter_id

  metrika_oauth_token = var.metrika_oauth_token
  clickhouse_password = var.clickhouse_password

  clickhouse_cluster_id = module.clickhouse.cluster_id
  clickhouse_db         = module.clickhouse.db_name
  clickhouse_user       = module.clickhouse.db_user
}

# ══════════════════════════════════════════════════════════════
# Scheduler: ежедневный запуск трансформации
# ══════════════════════════════════════════════════════════════

module "scheduler" {
  source = "./modules/scheduler"

  name            = "${local.prefix}-daily"
  folder_id       = var.folder_id
  function_id     = module.function.function_id
  invoker_sa_id   = yandex_iam_service_account.function.id
  cron_expression = var.cron_expression

  depends_on = [yandex_resourcemanager_folder_iam_member.function_invoker]
}
