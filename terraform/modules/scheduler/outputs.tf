output "trigger_id" {
  description = "ID триггера Cloud Scheduler"
  value       = yandex_function_trigger.daily.id
}
