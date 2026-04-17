output "transfer_id" {
  description = "ID Data Transfer трансфера"
  value       = yandex_datatransfer_transfer.main.id
}

output "target_endpoint_id" {
  description = "ID endpoint'а приёмника (ClickHouse)"
  value       = yandex_datatransfer_endpoint.target.id
}
