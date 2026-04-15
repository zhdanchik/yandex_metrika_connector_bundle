output "secret_id" {
  description = "Lockbox secret ID — передаётся в Cloud Function как LOCKBOX_SECRET_ID"
  value       = yandex_lockbox_secret.main.id
}

output "secret_version_id" {
  description = "ID текущей версии секрета"
  value       = yandex_lockbox_secret_version.main.id
}
