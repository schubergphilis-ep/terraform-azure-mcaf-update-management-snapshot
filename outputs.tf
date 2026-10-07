output "logic_app_id" {
  description = "Resource ID of the snapshot Logic App."
  value       = azapi_resource.snapshot.id
}

output "principal_id" {
  description = "Principal ID of the Logic App's system-assigned identity. Use it when `assign_roles = false`."
  value       = azapi_resource.snapshot.identity[0].principal_id
}

output "target_tag" {
  description = "Tag that marks a maintenance configuration as managed by this snapshot. Set by terraform-azure-mcaf-update-management when `snapshot_managed = true`."
  value       = { (local.target_tag_name) = local.target_tag_value }
}

output "schedule" {
  description = "Effective snapshot moment."
  value = {
    cadence           = var.schedule.cadence
    weekday           = local.weekday
    time              = format("%02d:%02d", var.schedule.hour, var.schedule.minute)
    time_zone         = var.schedule.time_zone
    days              = local.weekly ? "every week" : "day ${local.day_min}-${local.day_max} of the month"
    operating_systems = keys(local.os)
  }
}

output "alert_id" {
  description = "ID of the failed-run metric alert. Null when `failed_run_alert` is null."
  value       = one(azurerm_monitor_metric_alert.runs_failed[*].id)
}
