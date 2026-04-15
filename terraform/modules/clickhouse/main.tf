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
    assign_public_ip = false
  }

  database {
    name = var.db_name
  }

  user {
    name     = var.db_user
    password = var.clickhouse_password
    permission {
      database_name = var.db_name
    }
  }

  security_group_ids = var.security_group_ids
}

locals {
  host = yandex_mdb_clickhouse_cluster.main.host[0].fqdn
}

# Применяет DDL из sql/01_schema.sql сразу после создания кластера.
# Перезапускается только при изменении самой схемы или пересоздании кластера.
# Требует: clickhouse-client >= 21.1 на машине, запускающей terraform apply.
resource "null_resource" "schema" {
  depends_on = [yandex_mdb_clickhouse_cluster.main]

  triggers = {
    schema_hash = filemd5("${path.module}/../../../sql/01_schema.sql")
    cluster_id  = yandex_mdb_clickhouse_cluster.main.id
  }

  provisioner "local-exec" {
    # Пароль передаётся через переменную окружения — не виден в ps aux.
    environment = {
      CH_HOST     = local.host
      CH_USER     = var.db_user
      CH_PASSWORD = var.clickhouse_password
      CH_DB       = var.db_name
    }
    command = <<-EOT
      clickhouse-client \
        --host     "$CH_HOST" \
        --port     9440 \
        --secure   \
        --user     "$CH_USER" \
        --password "$CH_PASSWORD" \
        --database "$CH_DB" \
        --multiquery \
        < "${path.module}/../../../sql/01_schema.sql"
    EOT
  }
}
