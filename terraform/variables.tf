# ──────────────────────────────────────────────────────────────
# Обязательные параметры Yandex Cloud
# ──────────────────────────────────────────────────────────────

variable "folder_id" {
  description = "ID каталога Yandex Cloud, в котором создаются все ресурсы"
  type        = string
}

variable "network_id" {
  description = "ID VPC-сети для кластера ClickHouse и функции"
  type        = string
}

variable "subnet_id" {
  description = "ID подсети для хоста ClickHouse (должна быть в zone)"
  type        = string
}

# ──────────────────────────────────────────────────────────────
# Metrika source endpoint (создаётся вручную в YC Console)
# ──────────────────────────────────────────────────────────────

variable "metrika_source_endpoint_id" {
  description = <<EOT
ID заранее созданного в YC Console Metrika source endpoint (формат dte...).

Создаётся один раз:
  Data Transfer → Endpoints → Create endpoint → Source → Metrica.
  Укажи counter_id, OAuth-токен Метрики, период выгрузки.

Причина ручного шага: поле `period` (диапазон дат snapshot) — write-only
в публичном API YC, его нельзя задать через Terraform/SDK/CLI.
EOT
  type        = string
}

# ──────────────────────────────────────────────────────────────
# Секреты (чувствительные, не попадают в лог terraform plan)
# ──────────────────────────────────────────────────────────────

variable "clickhouse_password" {
  description = "Пароль пользователя ClickHouse"
  type        = string
  sensitive   = true
}

# ──────────────────────────────────────────────────────────────
# Параметры пайплайна
# ──────────────────────────────────────────────────────────────

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

# ──────────────────────────────────────────────────────────────
# Параметры именования и инфраструктуры
# ──────────────────────────────────────────────────────────────

variable "name" {
  description = "Префикс для имён всех создаваемых ресурсов"
  type        = string
  default     = "metrika-attribution"
}

variable "zone" {
  description = "Зона доступности для хоста ClickHouse"
  type        = string
  default     = "ru-central1-a"
}

variable "function_bucket_name" {
  description = "Глобально уникальное имя Object Storage бакета для zip-архива функции"
  type        = string
}

variable "cron_expression" {
  description = "Cron-расписание запуска трансформации (Quartz, UTC)"
  type        = string
  default     = "0 3 * * ?"  # 03:00 UTC ежедневно (YC cron: min hour dom month dow, dow=?)
}

variable "ca_cert_path" {
  description = "Путь к Yandex CA-сертификату для TLS-проверки при DDL-провизионинге. Скачивается через scripts/prepare.sh."
  type        = string
  default     = "../functions/transform/CA.pem"
}
