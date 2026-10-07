# Defaults: one Logic App, weekly on Monday 07:00, Windows and Linux, roles on every scope entry.

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
  subscription_ids    = ["00000000-0000-0000-0000-000000000000", "33333333-3333-3333-3333-333333333333"]
}

run "defaults" {
  command = plan

  assert {
    condition     = azapi_resource.snapshot.name == "update-snapshot" && azapi_resource.snapshot.location == "westeurope"
    error_message = "Unexpected name or location."
  }
  assert {
    condition     = azapi_resource.snapshot.body.properties.definition.triggers.Snapshot_day.recurrence.schedule.weekDays == ["Monday"] && azapi_resource.snapshot.body.properties.definition.triggers.Snapshot_day.recurrence.schedule.hours == [7] && azapi_resource.snapshot.body.properties.definition.triggers.Snapshot_day.recurrence.schedule.minutes == [0]
    error_message = "Default snapshot moment should be Monday 07:00."
  }
  assert {
    condition     = output.schedule.days == "every week" && output.schedule.operating_systems == ["linux", "windows"]
    error_message = "Weekly cadence for both operating systems expected."
  }
  assert {
    condition     = alltrue([for a in ["windows_query", "windows_list", "linux_query", "linux_list", "Count_assessed", "Require_assessment_data", "Find_targets", "Targets"] : contains(keys(azapi_resource.snapshot.body.properties.definition.actions), a)])
    error_message = "Expected actions missing."
  }
  assert {
    condition     = contains(keys(azapi_resource.snapshot.body.properties.definition.actions.Targets.actions), "windows_part") && contains(keys(azapi_resource.snapshot.body.properties.definition.actions.Targets.actions), "linux_part")
    error_message = "Both OS parts must be written by the same Logic App."
  }
  assert {
    condition     = strcontains(azapi_resource.snapshot.body.properties.definition.actions.Targets.actions.Intended.inputs, "outputs('windows_part')") && strcontains(azapi_resource.snapshot.body.properties.definition.actions.Targets.actions.Intended.inputs, "outputs('linux_part')")
    error_message = "Both OS blocks must go into one PATCH."
  }
  assert {
    condition     = length(azurerm_role_assignment.this) == 4
    error_message = "Expected 2 subscriptions x 2 roles."
  }
  assert {
    condition     = strcontains(azapi_resource.snapshot.body.properties.definition.actions.linux_query.inputs.body.query, "'='")
    error_message = "Linux masks must be built as name=version."
  }
  assert {
    condition     = output.target_tag == { "aum-snapshot" = "managed" }
    error_message = "Target tag must match terraform-azure-mcaf-update-management."
  }
}

run "empty_snapshot_writes_placeholder_not_nothing" {
  command = plan

  assert {
    condition     = strcontains(azapi_resource.snapshot.body.properties.definition.actions.Targets.actions.linux_part.inputs, "json('[\"aum-snapshot-placeholder=0.0.0\"]')") && strcontains(azapi_resource.snapshot.body.properties.definition.actions.Targets.actions.windows_part.inputs, "json('[\"9999999\"]')")
    error_message = "An empty list without classifications must become the never-matching placeholder."
  }
  assert {
    condition     = strcontains(azapi_resource.snapshot.body.properties.definition.actions.Targets.actions.windows_part.inputs, "classificationsToInclude")
    error_message = "Placeholder decision must look at the configuration's classifications."
  }
  assert {
    condition     = !contains(keys(azapi_resource.snapshot.body.properties.definition.actions), "Guard_empty_list")
    error_message = "An empty snapshot must not stop the run anymore."
  }
}

run "no_assessment_data_fails" {
  command = plan

  assert {
    condition     = azapi_resource.snapshot.body.properties.definition.actions.Require_assessment_data.else.actions.No_assessment_data.inputs.runStatus == "Failed"
    error_message = "Missing assessment data must fail the run."
  }
  assert {
    condition     = strcontains(azapi_resource.snapshot.body.properties.definition.actions.Count_assessed.inputs.body.query, "ago(48h)")
    error_message = "Assessment data must be recent."
  }
}

run "linux_only_with_filter_and_no_roles" {
  command = plan

  variables {
    operating_systems = {
      windows = { enabled = false }
      linux   = { classifications = ["Critical", "Security"] }
    }
    assign_roles = false
    name         = "teamx-snapshot"
  }

  assert {
    condition     = !contains(keys(azapi_resource.snapshot.body.properties.definition.actions), "windows_query") && !contains(keys(azapi_resource.snapshot.body.properties.definition.actions.Targets.actions), "windows_part")
    error_message = "A disabled OS must not be queried or written."
  }
  assert {
    condition     = strcontains(azapi_resource.snapshot.body.properties.definition.actions.linux_query.inputs.body.query, "has_any (dynamic(['Critical', 'Security']))")
    error_message = "Classification filter missing from the Linux query."
  }
  assert {
    condition     = length(azurerm_role_assignment.this) == 0 && azapi_resource.snapshot.name == "teamx-snapshot"
    error_message = "No roles expected, name not applied."
  }
}
