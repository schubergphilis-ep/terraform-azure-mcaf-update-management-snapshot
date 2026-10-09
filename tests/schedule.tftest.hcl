# Schedule variants: monthly relative to Patch Tuesday and a custom weekly moment.

mock_provider "azurerm" {
  override_during = plan
  source          = "./tests/mocks/azurerm"
}

mock_provider "azapi" {
  override_during = plan
  source          = "./tests/mocks/azapi"
}

variables {
  resource_group_name = "test-rg"
  subscription_ids    = ["00000000-0000-0000-0000-000000000000"]
}

run "monthly_monday_after_patch_tuesday" {
  command = plan

  variables {
    schedule = { cadence = "monthly", patch_tuesday_offset_days = 6 }
  }

  assert {
    condition     = azapi_resource.snapshot.body.properties.definition.triggers.Snapshot_day.recurrence.schedule.weekDays == ["Monday"] && output.schedule.days == "day 14-20 of the month"
    error_message = "Offset 6 should be Monday, day 14-20."
  }
}

run "monthly_wednesday_after_patch_tuesday" {
  command = plan

  variables {
    schedule = { cadence = "monthly", patch_tuesday_offset_days = 1, hour = 6 }
  }

  assert {
    condition     = azapi_resource.snapshot.body.properties.definition.triggers.Snapshot_day.recurrence.schedule.weekDays == ["Wednesday"] && output.schedule.days == "day 9-15 of the month" && output.schedule.time == "06:00"
    error_message = "Offset 1 should be Wednesday 06:00, day 9-15."
  }
}

run "weekly_custom" {
  command = plan

  variables {
    schedule = { weekday = "Thursday", hour = 23, minute = 55, time_zone = "UTC" }
  }

  assert {
    condition     = azapi_resource.snapshot.body.properties.definition.triggers.Snapshot_day.recurrence.schedule.weekDays == ["Thursday"] && output.schedule.time == "23:55" && azapi_resource.snapshot.body.properties.definition.triggers.Snapshot_day.recurrence.timeZone == "UTC"
    error_message = "Custom weekly moment not applied."
  }
}
