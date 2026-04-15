variable "name" {
  description = "Префикс для имён endpoint'ов и transfer'а"
  type        = string
}

variable "folder_id" {
  description = "Yandex Cloud folder ID"
  type        = string
}

variable "service_account_id" {
  description = "ID сервисного аккаунта Data Transfer (создаётся в корневом модуле)"
  type        = string
}

# --- Секреты (передаются напрямую, т.к. secret_ref не поддерживается провайдером) ---

variable "metrika_oauth_token" {
  description = "OAuth-токен Яндекс Метрики для источника Data Transfer"
  type        = string
  sensitive   = true
}

variable "clickhouse_password" {
  description = "Пароль пользователя ClickHouse для приёмника Data Transfer"
  type        = string
  sensitive   = true
}

# --- Источник: Яндекс Метрика ---

variable "counter_id" {
  description = "Номер счётчика Яндекс Метрики"
  type        = number
}

# --- Приёмник: Managed ClickHouse ---

variable "clickhouse_cluster_id" {
  description = "ID кластера Managed ClickHouse (из output модуля clickhouse)"
  type        = string
}

variable "clickhouse_db" {
  description = "Имя базы данных ClickHouse"
  type        = string
  default     = "default"
}

variable "clickhouse_user" {
  description = "Имя пользователя ClickHouse"
  type        = string
  default     = "default"
}
