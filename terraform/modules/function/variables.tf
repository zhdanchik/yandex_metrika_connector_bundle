variable "name" {
  description = "Имя Cloud Function (также используется как префикс для SA бакета)"
  type        = string
}

variable "folder_id" {
  description = "Yandex Cloud folder ID"
  type        = string
}

variable "service_account_id" {
  description = "ID сервисного аккаунта функции (создаётся в корневом модуле)"
  type        = string
}

variable "bucket_name" {
  description = "Имя Object Storage бакета для zip-архива функции (глобально уникальное в YC)"
  type        = string
}

# --- Lockbox ---

variable "lockbox_secret_id" {
  description = "ID Lockbox-секрета; передаётся в функцию как LOCKBOX_SECRET_ID"
  type        = string
}

# --- ClickHouse (только несекретные параметры) ---

variable "clickhouse_host" {
  description = "FQDN хоста ClickHouse (из output модуля clickhouse)"
  type        = string
}

variable "clickhouse_http_port" {
  description = "HTTP(S)-порт ClickHouse (8443 для TLS, 8123 для plain)"
  type        = number
  default     = 8443
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

variable "clickhouse_tls" {
  description = "Использовать TLS для подключения к ClickHouse"
  type        = bool
  default     = true
}

# --- Параметры пайплайна ---

variable "counter_id" {
  description = "Номер счётчика Яндекс Метрики"
  type        = number
}

variable "goal_id" {
  description = "ID цели конверсии Яндекс Метрики"
  type        = number
}

variable "half_life_days" {
  description = "Полураспад модели Time Decay в днях"
  type        = number
  default     = 7.0
}

# --- Ресурсы функции ---

variable "memory" {
  description = "Оперативная память функции в мегабайтах"
  type        = number
  default     = 512
}

variable "execution_timeout" {
  description = "Таймаут выполнения функции в секундах"
  type        = number
  default     = 600
}

# --- Сеть ---

variable "network_id" {
  description = "VPC network ID для connectivity block (нужно если ClickHouse без публичного IP)"
  type        = string
  default     = ""
}
