output "function_id" {
  description = "ID Cloud Function"
  value       = yandex_function.main.id
}

output "function_sa_id" {
  description = "ID сервисного аккаунта функции — передаётся в модуль lockbox для выдачи lockbox.payloadViewer"
  value       = yandex_iam_service_account.function.id
}
