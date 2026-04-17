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

  # on_create_activate_mode не работает для SNAPSHOT_ONLY — провайдер
  # намеренно пропускает активацию (см. resource_yandex_datatransfer_transfer.go,
  # "if transfer.Type != TransferType_SNAPSHOT_ONLY { ... activate }").
  # Активация и ожидание DONE вынесены в null_resource.activate ниже.

  depends_on = [yandex_resourcemanager_folder_iam_member.ch_editor]
}

# ──────────────────────────────────────────────────────────────
# Активация SNAPSHOT_ONLY transfer'а + ожидание завершения.
#
# Provider не умеет, yc CLI умеет. Local-exec проверяет текущий
# статус, активирует если нужно, поллит каждые 15 сек до DONE.
# Timeout 30 мин. На ошибке провизионер падает → terraform apply
# падает и пользователь видит проблему.
#
# Повторный apply переопрашивает: если transfer уже RUNNING/DONE,
# шаг активации пропускается, только поллинг.
# ──────────────────────────────────────────────────────────────
resource "null_resource" "activate" {
  triggers = {
    transfer_id = yandex_datatransfer_transfer.main.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -eu
      TID="${yandex_datatransfer_transfer.main.id}"
      STATUS=$(yc datatransfer transfer get "$TID" --format json | jq -r '.status // "UNKNOWN"')
      echo ">> transfer $TID current status: $STATUS"

      case "$STATUS" in
        CREATED|NEW|STOPPED)
          echo ">> activating transfer"
          yc datatransfer transfer activate "$TID"
          ;;
        RUNNING|DONE|COMPLETED)
          echo ">> already active/done, skipping activation"
          ;;
        ERROR|FAILED|FAILED_AND_CLEANED)
          echo ">> transfer is in failure state ($STATUS) — fix the source config and re-run"
          exit 1
          ;;
      esac

      echo ">> polling until DONE (up to 30 min)"
      for i in $(seq 1 120); do
        STATUS=$(yc datatransfer transfer get "$TID" --format json | jq -r '.status // "UNKNOWN"')
        echo "   [$i/120] status=$STATUS"
        case "$STATUS" in
          DONE|COMPLETED)
            echo ">> snapshot finished"
            exit 0
            ;;
          ERROR|FAILED|FAILED_AND_CLEANED)
            echo ">> transfer failed — check: yc datatransfer transfer get $TID"
            exit 1
            ;;
        esac
        sleep 15
      done
      echo ">> timeout after 30 min — check: yc datatransfer transfer get $TID"
      exit 1
    EOT
  }
}
