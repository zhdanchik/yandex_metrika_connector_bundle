variable "name" {
  description = "Lockbox secret name"
  type        = string
}

variable "folder_id" {
  description = "Yandex Cloud folder ID"
  type        = string
}

variable "clickhouse_password" {
  description = "ClickHouse user password"
  type        = string
  sensitive   = true
}

variable "metrika_oauth_token" {
  description = "Yandex Metrika OAuth token used by Data Transfer"
  type        = string
  sensitive   = true
}

variable "function_sa_id" {
  description = "Service account ID of the Cloud Function (granted lockbox.payloadViewer)"
  type        = string
}

variable "transfer_sa_id" {
  description = "Service account ID of the Data Transfer (granted lockbox.payloadViewer)"
  type        = string
}
