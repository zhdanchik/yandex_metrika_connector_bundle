# Ежедневный триггер Cloud Scheduler → Cloud Function.
#
# invoker_sa_id должен иметь роль serverless.functions.invoker
# на папку (выдаётся в корневом модуле).
resource "yandex_function_trigger" "daily" {
  name      = var.name
  folder_id = var.folder_id

  timer {
    cron_expression = var.cron_expression
  }

  function {
    id                 = var.function_id
    service_account_id = var.invoker_sa_id
    retry_attempts     = var.retry_attempts
    retry_interval     = var.retry_interval
  }
}
