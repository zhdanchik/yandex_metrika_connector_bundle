variable "name" {
  description = "Имя кластера Managed ClickHouse"
  type        = string
}

variable "folder_id" {
  description = "Yandex Cloud folder ID"
  type        = string
}

variable "network_id" {
  description = "VPC network ID, в которой размещается кластер"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID для хоста ClickHouse"
  type        = string
}

variable "zone" {
  description = "Зона доступности хоста"
  type        = string
  default     = "ru-central1-a"
}

variable "environment" {
  description = "Окружение кластера: PRODUCTION или PRESTABLE"
  type        = string
  default     = "PRODUCTION"
}

variable "resource_preset_id" {
  description = "Класс хоста ClickHouse (например s3-c2-m8 — 2 vCPU, 8 GB RAM)"
  type        = string
  default     = "s3-c2-m8"
}

variable "disk_size" {
  description = "Размер диска хоста в гигабайтах"
  type        = number
  default     = 50
}

variable "db_name" {
  description = "Имя базы данных ClickHouse (не может быть 'default' — эта БД уже существует в кластере)"
  type        = string
  default     = "metrika"
}

variable "db_user" {
  description = "Имя пользователя ClickHouse"
  type        = string
  default     = "default"
}

variable "clickhouse_password" {
  description = "Пароль пользователя ClickHouse (тот же, что кладётся в Lockbox)"
  type        = string
  sensitive   = true
}

variable "deletion_protection" {
  description = "Защита кластера от случайного удаления"
  type        = bool
  default     = false
}

variable "security_group_ids" {
  description = "Список ID групп безопасности для хоста (пусто — доступ по умолчанию)"
  type        = list(string)
  default     = []
}
