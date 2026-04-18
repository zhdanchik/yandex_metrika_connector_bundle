variable "name" {
  description = "Префикс для имён NAT-ресурсов"
  type        = string
}

variable "folder_id" {
  description = "Yandex Cloud folder ID"
  type        = string
}

variable "network_id" {
  description = "VPC network ID, в которой лежит subnet_id"
  type        = string
}

variable "subnet_id" {
  description = "ID подсети Cloud Function — к ней будет привязана route-table с маршрутом 0.0.0.0/0 → gateway"
  type        = string
}
