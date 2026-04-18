# ──────────────────────────────────────────────────────────────
# Cloud NAT: shared-egress gateway + route-table + привязка к подсети
#
# Cloud Function должна достучаться до Lockbox API
# (payload.lockbox.api.cloud.yandex.net) и metadata-сервиса.
# Для этого подсети нужна default-route в shared-egress gateway.
#
# Подсеть передаётся снаружи (var.subnet_id) — она НЕ управляется
# этим модулем. Привязка route-table делается через local-exec
# на yc CLI, т.к. Terraform-провайдер не умеет модифицировать
# неимпортированный yandex_vpc_subnet.
# ──────────────────────────────────────────────────────────────

resource "yandex_vpc_gateway" "egress" {
  name      = "${var.name}-egress-nat"
  folder_id = var.folder_id

  shared_egress_gateway {}
}

resource "yandex_vpc_route_table" "egress" {
  name       = "${var.name}-egress-rt"
  folder_id  = var.folder_id
  network_id = var.network_id

  static_route {
    destination_prefix = "0.0.0.0/0"
    gateway_id         = yandex_vpc_gateway.egress.id
  }
}

# Привязка route-table к подсети. yc CLI идемпотентен: повторный
# вызов с тем же --route-table-id = no-op.
resource "null_resource" "bind_route_table" {
  triggers = {
    subnet_id      = var.subnet_id
    route_table_id = yandex_vpc_route_table.egress.id
  }

  provisioner "local-exec" {
    command = "yc vpc subnet update --id ${var.subnet_id} --route-table-id ${yandex_vpc_route_table.egress.id}"
  }
}
