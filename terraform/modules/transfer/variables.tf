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

# --- Источник: UI-созданный Metrika endpoint ---

variable "metrika_source_endpoint_id" {
  description = <<EOT
ID заранее созданного в UI Metrika source endpoint (dte...).
Создаётся один раз через YC Console:
  Data Transfer → Endpoints → Создать endpoint → Источник → Metrica.
Поле `period` (диапазон дат) — UI-only, поэтому source не управляется
Terraform'ом.
EOT
  type        = string
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

variable "clickhouse_password" {
  description = "Пароль пользователя ClickHouse для приёмника Data Transfer"
  type        = string
  sensitive   = true
}
