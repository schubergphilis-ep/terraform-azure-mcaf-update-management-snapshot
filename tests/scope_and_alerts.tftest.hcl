# Scope (subscriptions or management groups, with excludes) and the optional failed-run alert.

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
}

run "management_group_with_excludes" {
  command = plan

  variables {
    management_group_ids     = ["mg-landingzones"]
    exclude_subscription_ids = ["44444444-4444-4444-4444-444444444444"]
  }

  assert {
    condition     = azapi_resource.snapshot.body.properties.definition.actions.windows_query.inputs.body.managementGroups == tolist(["mg-landingzones"])
    error_message = "Resource Graph must be scoped to the management group."
  }
  assert {
    condition     = !contains(keys(azapi_resource.snapshot.body.properties.definition.actions.windows_query.inputs.body), "subscriptions")
    error_message = "No subscriptions key when scoped to management groups."
  }
  assert {
    condition = alltrue([
      for q in [
        azapi_resource.snapshot.body.properties.definition.actions.windows_query.inputs.body.query,
        azapi_resource.snapshot.body.properties.definition.actions.linux_query.inputs.body.query,
        azapi_resource.snapshot.body.properties.definition.actions.Find_targets.inputs.body.query,
        azapi_resource.snapshot.body.properties.definition.actions.Count_assessed.inputs.body.query,
      ] : strcontains(q, "subscriptionId !in~ ('44444444-4444-4444-4444-444444444444')")
    ])
    error_message = "Excluded subscription must be filtered from assessment and target queries."
  }
  assert {
    condition     = alltrue([for r in azurerm_role_assignment.this : r.scope == "/providers/Microsoft.Management/managementGroups/mg-landingzones"]) && length(azurerm_role_assignment.this) == 2
    error_message = "Roles must be assigned on the management group: 2 roles."
  }
  assert {
    condition     = length(azurerm_monitor_metric_alert.runs_failed) == 0
    error_message = "No alerts without an action group."
  }
}

run "subscriptions_without_excludes" {
  command = plan

  variables {
    subscription_ids = ["00000000-0000-0000-0000-000000000000"]
  }

  assert {
    condition     = azapi_resource.snapshot.body.properties.definition.actions.Find_targets.inputs.body.subscriptions == tolist(["00000000-0000-0000-0000-000000000000"])
    error_message = "Resource Graph must be scoped to the subscription."
  }
  assert {
    condition     = !strcontains(azapi_resource.snapshot.body.properties.definition.actions.Find_targets.inputs.body.query, "!in~")
    error_message = "No exclude filter without excludes."
  }
}

run "alert_per_logic_app" {
  command = plan

  variables {
    subscription_ids = ["00000000-0000-0000-0000-000000000000"]
    failed_run_alert = {
      action_group_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Insights/actionGroups/ops"
    }
  }

  assert {
    condition     = length(azurerm_monitor_metric_alert.runs_failed) == 1
    error_message = "Expected one alert for the Logic App."
  }
  assert {
    condition     = azurerm_monitor_metric_alert.runs_failed[0].criteria[0].metric_name == "RunsFailed" && azurerm_monitor_metric_alert.runs_failed[0].criteria[0].threshold == 0
    error_message = "Alert must fire on any failed run."
  }
  assert {
    condition     = azurerm_monitor_metric_alert.runs_failed[0].name == "update-snapshot-runs-failed" && azurerm_monitor_metric_alert.runs_failed[0].severity == 2
    error_message = "Unexpected alert name or severity."
  }
}
