resource "yandex_lockbox_secret" "main" {
  name      = var.name
  folder_id = var.folder_id
}

resource "yandex_lockbox_secret_version" "main" {
  secret_id = yandex_lockbox_secret.main.id

  entries {
    key        = "clickhouse_password"
    text_value = var.clickhouse_password
  }
}

# Cloud Function reads clickhouse_password at runtime.
resource "yandex_lockbox_secret_iam_member" "function_viewer" {
  secret_id = yandex_lockbox_secret.main.id
  role      = "lockbox.payloadViewer"
  member    = "serviceAccount:${var.function_sa_id}"
}
