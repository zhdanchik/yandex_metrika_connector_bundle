variable "name" {
  description = "Имя триггера Cloud Scheduler"
  type        = string
}

variable "folder_id" {
  description = "Yandex Cloud folder ID"
  type        = string
}

variable "function_id" {
  description = "ID Cloud Function, которую запускает триггер"
  type        = string
}

variable "invoker_sa_id" {
  description = "ID сервисного аккаунта с ролью serverless.functions.invoker"
  type        = string
}

variable "cron_expression" {
  description = "Cron-выражение в формате Quartz (6 полей: сек мин час день мес д.нед)"
  type        = string
  default     = "0 0 3 * * ?"  # 03:00 UTC ежедневно
}

variable "retry_attempts" {
  description = "Число повторных попыток при ошибке функции"
  type        = number
  default     = 1
}

variable "retry_interval" {
  description = "Интервал между повторными попытками в секундах"
  type        = number
  default     = 60
}
