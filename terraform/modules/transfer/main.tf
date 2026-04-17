# Роль для записи в Managed ClickHouse (нужна сервисному аккаунту transfer'а).
resource "yandex_resourcemanager_folder_iam_member" "ch_editor" {
  folder_id = var.folder_id
  role      = "managed-clickhouse.editor"
  member    = "serviceAccount:${var.service_account_id}"
}

# ──────────────────────────────────────────────────────────────
# Endpoint: приёмник — Managed ClickHouse
#
# Источник (Яндекс Метрика) создаётся ПОЛЬЗОВАТЕЛЕМ в UI один раз
# и передаётся сюда как var.metrika_source_endpoint_id. Причина —
# поле `period` (диапазон дат snapshot) write-only в публичном
# API YC: нет ни в proto, ни в Terraform-провайдере, ни в SDK,
# ни в yc CLI. UI сохраняет его через приватный API.
# ──────────────────────────────────────────────────────────────
resource "yandex_datatransfer_endpoint" "target" {
  name      = "${var.name}-target"
  folder_id = var.folder_id

  settings {
    clickhouse_target {
      connection {
        connection_options {
          mdb_cluster_id = var.clickhouse_cluster_id
          database       = var.clickhouse_db
          user           = var.clickhouse_user

          password {
            raw = var.clickhouse_password
          }
        }
      }

      # Шардирование по CounterUserIDHash — равномерное распределение визитов.
      sharding {
        column_value_hash {
          column_name = "CounterUserIDHash"
        }
      }

      # Не очищать таблицу перед репликацией — VersionedCollapsingMergeTree
      # обрабатывает дубли и отмены через Sign/VisitVersion.
      cleanup_policy = "CLICKHOUSE_CLEANUP_POLICY_DISABLED"
    }
  }
}

# ──────────────────────────────────────────────────────────────
# Transfer: SNAPSHOT_ONLY (Metrika Logs API пакетный, инкремент не поддержан)
# ──────────────────────────────────────────────────────────────
resource "yandex_datatransfer_transfer" "main" {
  name      = var.name
  folder_id = var.folder_id
  source_id = var.metrika_source_endpoint_id
  target_id = yandex_datatransfer_endpoint.target.id
  type      = "SNAPSHOT_ONLY"

  # Активировать синхронно: terraform apply ждёт, пока snapshot
  # фактически завершится. Для SNAPSHOT_ONLY transfer'а это значит
  # «данные загружены в ClickHouse» — smoke.sh сразу после apply
  # увидит заполненную таблицу visits_<transfer_id>.
  on_create_activate_mode = "sync_activate"

  depends_on = [yandex_resourcemanager_folder_iam_member.ch_editor]
}
