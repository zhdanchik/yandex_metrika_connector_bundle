# ──────────────────────────────────────────────────────────────
# Service account для записи zip в Object Storage
# Изолирован от function SA: статический ключ хранится в Terraform
# state только для нужд upload'а, не для рантайма функции.
# ──────────────────────────────────────────────────────────────
resource "yandex_iam_service_account" "storage" {
  name      = "${var.name}-storage-sa"
  folder_id = var.folder_id
}

resource "yandex_resourcemanager_folder_iam_member" "storage_editor" {
  folder_id = var.folder_id
  role      = "storage.editor"
  member    = "serviceAccount:${yandex_iam_service_account.storage.id}"
}

resource "yandex_iam_service_account_static_access_key" "storage" {
  service_account_id = yandex_iam_service_account.storage.id
}

# ──────────────────────────────────────────────────────────────
# Object Storage: бакет + zip-архив кода функции
# ──────────────────────────────────────────────────────────────
resource "yandex_storage_bucket" "function" {
  bucket     = var.bucket_name
  folder_id  = var.folder_id
  access_key = yandex_iam_service_account_static_access_key.storage.access_key
  secret_key = yandex_iam_service_account_static_access_key.storage.secret_key
}

# Упаковывает functions/transform/ в zip при каждом изменении кода.
data "archive_file" "function" {
  type        = "zip"
  source_dir  = "${path.module}/../../../functions/transform"
  output_path = "/tmp/${var.name}-function.zip"
}

resource "yandex_storage_object" "function_zip" {
  bucket     = yandex_storage_bucket.function.bucket
  key        = "function.zip"
  source     = data.archive_file.function.output_path
  access_key = yandex_iam_service_account_static_access_key.storage.access_key
  secret_key = yandex_iam_service_account_static_access_key.storage.secret_key

  depends_on = [data.archive_file.function]
}

# ──────────────────────────────────────────────────────────────
# Cloud Function
#
# Env-переменные содержат только несекретные параметры.
# Секреты (clickhouse_password) читаются функцией из Lockbox
# в рантайме через _get_lockbox_payload() в handler.py.
# ──────────────────────────────────────────────────────────────
resource "yandex_function" "main" {
  name      = var.name
  folder_id = var.folder_id

  runtime            = "python311"
  entrypoint         = "handler.handler"
  memory             = var.memory
  execution_timeout  = tostring(var.execution_timeout)
  service_account_id = var.service_account_id

  # Изменение sha256 перезапускает деплой функции.
  user_hash = data.archive_file.function.output_sha256

  package {
    bucket_name = yandex_storage_bucket.function.bucket
    object_name = yandex_storage_object.function_zip.key
    sha_256     = data.archive_file.function.output_sha256
  }

  environment = {
    LOCKBOX_SECRET_ID = var.lockbox_secret_id
    CLICKHOUSE_HOST   = var.clickhouse_host
    CLICKHOUSE_PORT   = tostring(var.clickhouse_port)
    CLICKHOUSE_DB     = var.clickhouse_db
    CLICKHOUSE_USER   = var.clickhouse_user
    CLICKHOUSE_TLS    = var.clickhouse_tls ? "1" : "0"
    COUNTER_ID        = tostring(var.counter_id)
    GOAL_ID           = tostring(var.goal_id)
    HALF_LIFE_DAYS    = tostring(var.half_life_days)
  }

  # Подключение к внутренней VPC — нужно если ClickHouse без публичного IP.
  dynamic "connectivity" {
    for_each = var.network_id != "" ? [var.network_id] : []
    content {
      network_id = connectivity.value
    }
  }
}
