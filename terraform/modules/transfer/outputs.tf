output "transfer_id" {
  description = "ID Data Transfer трансфера"
  value       = yandex_datatransfer_transfer.main.id
}

output "source_endpoint_id" {
  description = "ID endpoint'а источника (Яндекс Метрика)"
  value       = yandex_datatransfer_endpoint.source.id
}

output "target_endpoint_id" {
  description = "ID endpoint'а приёмника (ClickHouse)"
  value       = yandex_datatransfer_endpoint.target.id
}
