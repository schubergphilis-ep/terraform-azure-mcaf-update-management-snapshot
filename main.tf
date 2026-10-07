data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

# How the Logic App works: see README.md, section "How it works".
resource "azapi_resource" "snapshot" {
  type      = "Microsoft.Logic/workflows@2019-05-01"
  name      = var.name
  parent_id = data.azurerm_resource_group.this.id
  location  = local.location
  tags      = var.tags

  identity {
    type = "SystemAssigned"
  }

  body = {
    properties = {
      state      = "Enabled"
      parameters = {}
      definition = {
        "$schema"      = "https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#"
        contentVersion = "1.0.0.0"
        parameters     = {}
        outputs        = {}

        triggers = {
          Snapshot_day = {
            type = "Recurrence"
            recurrence = {
              frequency = "Week"
              interval  = 1
              timeZone  = var.schedule.time_zone
              # A start time in the past prevents an immediate run on deployment.
              startTime = "2025-01-01T00:00:00"
              schedule = {
                weekDays = [local.weekday]
                hours    = [var.schedule.hour]
                minutes  = [var.schedule.minute]
              }
            }
          }
        }

        actions = merge(
          {
            Only_snapshot_day = {
              type = "If"
              expression = {
                and = [
                  { greaterOrEquals = ["@dayOfMonth(convertFromUtc(utcNow(), '${var.schedule.time_zone}'))", local.day_min] },
                  { lessOrEquals = ["@dayOfMonth(convertFromUtc(utcNow(), '${var.schedule.time_zone}'))", local.day_max] },
                ]
              }
              actions = {}
              else = {
                actions = {
                  Not_snapshot_week = {
                    type   = "Terminate"
                    inputs = { runStatus = "Cancelled" }
                  }
                }
              }
              runAfter = {}
            }

            Count_assessed = {
              type = "Http"
              inputs = {
                method         = "POST"
                uri            = local.arg_uri
                body           = merge(local.arg_scope, { query = trimspace(local.assessed_query), options = { resultFormat = "objectArray" } })
                authentication = local.msi_auth
              }
              runAfter = { Only_snapshot_day = ["Succeeded"] }
            }

            Require_assessment_data = {
              type       = "If"
              expression = { greater = ["@body('Count_assessed')?['data']?[0]?['Count']", 0] }
              actions    = {}
              else = {
                actions = {
                  No_assessment_data = {
                    type = "Terminate"
                    inputs = {
                      runStatus = "Failed"
                      runError = {
                        code    = "NoAssessmentData"
                        message = "No machine in scope has an Azure Update Manager assessment from the last 48 hours; include lists left unchanged."
                      }
                    }
                  }
                }
              }
              runAfter = { Count_assessed = ["Succeeded"] }
            }

            Find_targets = {
              type = "Http"
              inputs = {
                method         = "POST"
                uri            = local.arg_uri
                body           = merge(local.arg_scope, { query = trimspace(local.target_query), options = { resultFormat = "objectArray" } })
                authentication = local.msi_auth
              }
              runAfter = merge(
                { Require_assessment_data = ["Succeeded"] },
                { for os, s in local.os : "${os}_list" => ["Succeeded"] },
              )
            }

            Targets = {
              type    = "Foreach"
              foreach = "@body('Find_targets')?['data']"
              actions = merge(
                { for os, s in local.os : "${os}_part" => { type = "Compose", inputs = local.part_expr[os], runAfter = {} } },
                {
                  # Missing OS parts (disabled OS) are {} so the union below stays valid.
                  Intended = {
                    type     = "Compose"
                    inputs   = "@union(json('{}'), ${join(", ", [for os, s in local.os : "outputs('${os}_part')"])})"
                    runAfter = { for os, s in local.os : "${os}_part" => ["Succeeded"] }
                  }
                  Write_and_verify = {
                    type       = "Until"
                    expression = local.written_expr
                    limit      = { count = 5, timeout = "PT15M" }
                    actions = {
                      # One PATCH with every OS block of the configuration, so no block can overwrite another.
                      Patch_include_lists = {
                        type = "Http"
                        inputs = {
                          method         = "PATCH"
                          uri            = "https://management.azure.com@{items('Targets')['id']}?api-version=2023-04-01"
                          body           = { properties = { installPatches = "@outputs('Intended')" } }
                          authentication = local.msi_auth
                        }
                        runAfter = {}
                      }
                      Settle = {
                        type     = "Wait"
                        inputs   = { interval = { count = 20, unit = "Second" } }
                        runAfter = { Patch_include_lists = ["Succeeded", "Failed"] }
                      }
                      Read_back = {
                        type = "Http"
                        inputs = {
                          method         = "GET"
                          uri            = "https://management.azure.com@{items('Targets')['id']}?api-version=2023-04-01"
                          authentication = local.msi_auth
                        }
                        runAfter = { Settle = ["Succeeded"] }
                      }
                    }
                    runAfter = { Intended = ["Succeeded"] }
                  }
                  # Terminate is not allowed inside a loop; an invalid json() fails this action,
                  # the loop and the run, with the message visible in the run history.
                  Assert_written = {
                    type     = "Compose"
                    inputs   = "@if(${trimprefix(local.written_expr, "@")}, 'ok', json('INCLUDE LIST NOT PERSISTED AFTER 5 ATTEMPTS'))"
                    runAfter = { Write_and_verify = ["Succeeded", "Failed", "TimedOut"] }
                  }
                },
              )
              runAfter = { Find_targets = ["Succeeded"] }
            }
          },
          merge([
            for os, s in local.os : {
              "${os}_query" = {
                type = "Http"
                inputs = {
                  method         = "POST"
                  uri            = local.arg_uri
                  body           = merge(local.arg_scope, { query = trimspace(s.pending_query), options = { resultFormat = "objectArray" } })
                  authentication = local.msi_auth
                }
                runAfter = { Require_assessment_data = ["Succeeded"] }
              }
              "${os}_list" = {
                type     = "Select"
                inputs   = { from = "@body('${os}_query')?['data']", select = "@item()['item']" }
                runAfter = { "${os}_query" = ["Succeeded"] }
              }
            }
          ]...),
        )
      }
    }
  }
}

# Reader: Resource Graph only returns what the identity can read.
# Scheduled Patching Contributor: write maintenance configurations, nothing else.
resource "azurerm_role_assignment" "this" {
  for_each = local.role_assignments

  scope                = each.value.scope
  role_definition_name = each.value.role
  principal_id         = azapi_resource.snapshot.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

# Optional: alert when a snapshot run fails. A failed run leaves the include lists unchanged,
# so stages keep installing the previous list until someone looks.
resource "azurerm_monitor_metric_alert" "runs_failed" {
  count = var.failed_run_alert == null ? 0 : 1

  name                = "${var.name}-runs-failed"
  resource_group_name = var.resource_group_name
  scopes              = [azapi_resource.snapshot.id]
  description         = "Update snapshot run failed: include lists were not updated. Check the Logic App run history."
  severity            = var.failed_run_alert.severity
  frequency           = "PT5M"
  window_size         = "PT1H"
  tags                = var.tags

  criteria {
    metric_namespace = "Microsoft.Logic/workflows"
    metric_name      = "RunsFailed"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 0
  }

  action {
    action_group_id = var.failed_run_alert.action_group_id
  }
}
