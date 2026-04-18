output "gateway_id" {
  description = "ID shared-egress gateway"
  value       = yandex_vpc_gateway.egress.id
}

output "route_table_id" {
  description = "ID route-table с маршрутом 0.0.0.0/0 → gateway"
  value       = yandex_vpc_route_table.egress.id
}
