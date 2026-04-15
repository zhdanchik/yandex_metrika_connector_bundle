# Роль для записи в Managed ClickHouse (нужна сервисному аккаунту transfer'а).
resource "yandex_resourcemanager_folder_iam_member" "ch_editor" {
  folder_id = var.folder_id
  role      = "managed-clickhouse.editor"
  member    = "serviceAccount:${var.service_account_id}"
}

# ──────────────────────────────────────────────────────────────
# Endpoint: источник — Яндекс Метрика Logs API
#
# OAuth-токен берётся из Lockbox через secret_ref — в Terraform
# state токен не попадает.
# ──────────────────────────────────────────────────────────────
resource "yandex_datatransfer_endpoint" "source" {
  name      = "${var.name}-source"
  folder_id = var.folder_id

  settings {
    metrika_source {
      counter_ids = [var.counter_id]

      token {
        raw = var.metrika_oauth_token
      }

      streams {
        # Визиты: все поля, включая TrafficSource и Goals.
        type = "METRIKA_STREAM_TYPE_VISITS"
      }
    }
  }
}

# ──────────────────────────────────────────────────────────────
# Endpoint: приёмник — Managed ClickHouse
#
# Пароль берётся из Lockbox через secret_ref.
# Шардирование по UserIDHash — равномерное распределение визитов.
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

      sharding {
        column_value_hash {
          column_name = "UserIDHash"
        }
      }

      # Не очищать таблицу перед репликацией — CollapsingMergeTree
      # обрабатывает дубли и отмены через знак Sign.
      cleanup_policy = "CLICKHOUSE_CLEANUP_POLICY_DISABLED"
    }
  }
}

# ──────────────────────────────────────────────────────────────
# Transfer: Snapshot + Increment
#
# Начальный снимок + непрерывная репликация новых визитов.
# Запускается вручную после terraform apply или через UI YC.
# ──────────────────────────────────────────────────────────────
resource "yandex_datatransfer_transfer" "main" {
  name      = var.name
  folder_id = var.folder_id
  source_id = yandex_datatransfer_endpoint.source.id
  target_id = yandex_datatransfer_endpoint.target.id
  type      = "SNAPSHOT_AND_INCREMENT"

  depends_on = [yandex_resourcemanager_folder_iam_member.ch_editor]
}
