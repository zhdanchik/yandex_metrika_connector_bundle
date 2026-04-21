resource "yandex_mdb_clickhouse_cluster" "main" {
  name                = var.name
  environment         = var.environment
  network_id          = var.network_id
  folder_id           = var.folder_id
  deletion_protection = var.deletion_protection

  clickhouse {
    resources {
      resource_preset_id = var.resource_preset_id
      disk_type_id       = "network-ssd"
      disk_size          = var.disk_size
    }
  }

  host {
    type             = "CLICKHOUSE"
    zone             = var.zone
    subnet_id        = var.subnet_id
    assign_public_ip = var.assign_public_ip
  }

  # Разрешаем подключение DataLens к этому кластеру. Без этого флага
  # выбор кластера в DataLens UI при создании connection молча пустой.
  # Сама connection создаётся пользователем в UI (TF-провайдер пока
  # поддерживает yandex_datalens_connection только для YDB; как только
  # появится clickhouse-вариант, перенесём в module.datalens).
  access {
    data_lens = true
  }

  # database / user управляются отдельными ресурсами ниже —
  # nested-блоки deprecated начиная с yandex provider 0.199.

  security_group_ids = var.security_group_ids

  # После первичного создания кластера terraform может захотеть
  # «вернуть» user/database, упомянутые API при чтении (drift),
  # в момент, когда они управляются standalone ресурсами. Игнорим.
  lifecycle {
    ignore_changes = [database, user]
  }
}

resource "yandex_mdb_clickhouse_database" "main" {
  cluster_id = yandex_mdb_clickhouse_cluster.main.id
  name       = var.db_name
}

resource "yandex_mdb_clickhouse_user" "main" {
  cluster_id = yandex_mdb_clickhouse_cluster.main.id
  name       = var.db_user
  password   = var.clickhouse_password

  permission {
    database_name = yandex_mdb_clickhouse_database.main.name
  }
}

locals {
  host = yandex_mdb_clickhouse_cluster.main.host[0].fqdn
}

# Применяет DDL из sql/01_schema.sql сразу после создания кластера.
# Перезапускается только при изменении самой схемы или пересоздании кластера.
# Требует: clickhouse-client >= 21.1 + CA-сертификат YC в CA_CERT_PATH.
resource "null_resource" "schema" {
  depends_on = [
    yandex_mdb_clickhouse_cluster.main,
    yandex_mdb_clickhouse_database.main,
    yandex_mdb_clickhouse_user.main,
  ]

  triggers = {
    schema_hash = filemd5("${path.module}/../../../sql/01_schema.sql")
    cluster_id  = yandex_mdb_clickhouse_cluster.main.id
  }

  provisioner "local-exec" {
    # Пароль передаётся через XML-конфиг с chmod 600 — не виден в ps aux.
    environment = {
      CH_HOST     = local.host
      CH_USER     = var.db_user
      CH_PASSWORD = var.clickhouse_password
      CH_DB       = var.db_name
      CA_CERT     = var.ca_cert_path
    }
    command = <<-EOT
      set -euo pipefail

      if [ ! -f "$CA_CERT" ]; then
        echo "ERROR: CA certificate not found at $CA_CERT" >&2
        echo "Run scripts/prepare.sh before terraform apply, or set var.ca_cert_path" >&2
        exit 1
      fi

      # XML-конфиг содержит пароль И TLS-настройки с проверкой по YC CA.
      # Создаётся mktemp + chmod 600, чтобы другие пользователи не прочитали пароль.
      CH_CFG=$(mktemp -t ch-cfg.XXXXXX.xml)
      trap 'rm -f "$CH_CFG"' EXIT
      chmod 600 "$CH_CFG"

      # Exit-on-error ловим, python3 для escape'а пароля в XML (< > & " '\'').
      python3 - "$CH_USER" "$CH_PASSWORD" "$CA_CERT" > "$CH_CFG" <<'PY'
import sys, html
user, password, ca = sys.argv[1], sys.argv[2], sys.argv[3]
print(f"""<clickhouse>
  <user>{html.escape(user)}</user>
  <password>{html.escape(password)}</password>
  <openSSL>
    <client>
      <loadDefaultCAFile>false</loadDefaultCAFile>
      <caConfig>{html.escape(ca)}</caConfig>
      <verificationMode>strict</verificationMode>
      <invalidCertificateHandler><name>RejectCertificateHandler</name></invalidCertificateHandler>
    </client>
  </openSSL>
</clickhouse>""")
PY

      if command -v clickhouse-client >/dev/null 2>&1; then
        CH_BIN="clickhouse-client"
      else
        CH_BIN="clickhouse client"
      fi
      $CH_BIN \
        --config-file   "$CH_CFG" \
        --host          "$CH_HOST" \
        --port          9440 \
        --secure        \
        --database      "$CH_DB" \
        --multiquery    \
        < "${path.module}/../../../sql/01_schema.sql"
    EOT
  }
}
