locals {
  location = coalesce(var.location, data.azurerm_resource_group.this.location)

  # Contract with terraform-azure-mcaf-update-management (snapshot_managed = true): maintenance
  # configurations carrying this tag are updated; aum-snapshot-<os>-extras holds a comma-separated
  # list that is always added to the frozen list. The placeholders are the same never-matching
  # includes that module uses, because the Maintenance API rejects an OS block without
  # classifications and without includes.
  target_tag_name  = "aum-snapshot"
  target_tag_value = "managed"
  placeholder = {
    windows = "9999999"
    linux   = "aum-snapshot-placeholder=0.0.0"
  }

  # Schedule. Monthly derives the weekday from the offset to Patch Tuesday (second Tuesday, day 8-14)
  # and only lets the run through in that week; weekly lets every run through.
  weekly            = var.schedule.cadence == "weekly"
  weekdays_from_tue = ["Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday", "Monday"]
  weekday           = local.weekly ? var.schedule.weekday : local.weekdays_from_tue[var.schedule.patch_tuesday_offset_days % 7]
  day_min           = local.weekly ? 1 : 8 + var.schedule.patch_tuesday_offset_days
  day_max           = local.weekly ? 31 : 14 + var.schedule.patch_tuesday_offset_days

  # Scope of the Resource Graph queries and of the role assignments.
  arg_scope = length(var.management_group_ids) > 0 ? { managementGroups = var.management_group_ids } : { subscriptions = var.subscription_ids }
  exclude_filter = length(var.exclude_subscription_ids) == 0 ? "" : format(
    "| where subscriptionId !in~ (%s)",
    join(", ", [for id in var.exclude_subscription_ids : "'${id}'"])
  )
  role_scopes = length(var.management_group_ids) > 0 ? [
    for id in var.management_group_ids : "/providers/Microsoft.Management/managementGroups/${id}"
  ] : [for id in var.subscription_ids : "/subscriptions/${id}"]

  classification_filter = {
    for os, cfg in var.operating_systems : os => length(cfg.classifications) == 0 ? "" : format(
      "| where tostring(properties.classifications) has_any (dynamic([%s]))",
      join(", ", [for c in cfg.classifications : "'${c}'"])
    )
  }

  # Machines with an assessment in the last 48 hours. Zero means no usable data (assessment off or
  # broken), which must not be mistaken for "nothing to patch".
  assessed_query = <<-KQL
    patchassessmentresources
    | where type endswith '/patchassessmentresults'
    | where todatetime(properties.lastModifiedDateTime) > ago(48h)
    ${local.exclude_filter}
    | count
  KQL

  os_all = {
    windows = {
      params_key  = "windowsParameters"
      include_key = "kbNumbersToInclude"
      # Definition updates (Defender) are never frozen; the schedule's Definition classification installs them.
      pending_query = <<-KQL
        patchassessmentresources
        | where type endswith '/patchassessmentresults/softwarepatches'
        | where isnotempty(properties.kbId)
        | where not(tostring(properties.classifications) has 'Definition')
        ${local.exclude_filter}
        ${local.classification_filter.windows}
        | extend item = tostring(properties.kbId)
        | distinct item
        | order by item asc
      KQL
    }
    linux = {
      params_key  = "linuxParameters"
      include_key = "packageNameMasksToInclude"
      # Azure Update Manager matches Linux masks as name=version; name_version matches nothing.
      pending_query = <<-KQL
        patchassessmentresources
        | where type endswith '/patchassessmentresults/softwarepatches'
        | where isempty(properties.kbId) and isnotempty(properties.version)
        ${local.exclude_filter}
        ${local.classification_filter.linux}
        | extend item = strcat(tostring(properties.patchName), '=', tostring(properties.version))
        | distinct item
        | order by item asc
      KQL
    }
  }
  os = { for os, s in local.os_all : os => s if var.operating_systems[os].enabled }

  target_query = <<-KQL
    resources
    | where type =~ 'microsoft.maintenance/maintenanceconfigurations'
    | where tags['${local.target_tag_name}'] =~ '${local.target_tag_value}'
    ${local.exclude_filter}
    | project id, windows = properties.installPatches.windowsParameters, linux = properties.installPatches.linuxParameters,
      windows_extras = tostring(tags['${local.target_tag_name}-windows-extras']), linux_extras = tostring(tags['${local.target_tag_name}-linux-extras'])
  KQL

  # Per OS, per target configuration (Logic Apps expressions):
  #   include = snapshot + extras; empty with no classifications -> the placeholder (installs nothing).
  #   part    = { "<os>Parameters": current block with only the include key replaced }, or {} when the
  #             configuration has no block for this OS (a block is never added).
  include_expr = {
    for os, s in local.os : os => "union(body('${os}_list'), if(empty(items('Targets')['${os}_extras']), json('[]'), split(items('Targets')['${os}_extras'], ',')))"
  }
  part_expr = {
    for os, s in local.os : os => join("", [
      "@if(equals(items('Targets')?['${os}'], null), json('{}'), json(concat('{\"${s.params_key}\":', string(setProperty(items('Targets')['${os}'], '${s.include_key}', ",
      "if(and(empty(${local.include_expr[os]}), empty(coalesce(items('Targets')['${os}']?['classificationsToInclude'], json('[]')))), json('[\"${local.placeholder[os]}\"]'), ${local.include_expr[os]})",
      ")), '}')))",
    ])
  }
  # Written include lists equal the intended ones, for every OS block that was written.
  written_expr = format("@and(%s)", join(", ", concat([
    for os, s in local.os : "equals(string(body('Read_back')?['properties']?['installPatches']?['${s.params_key}']?['${s.include_key}']), string(outputs('Intended')?['${s.params_key}']?['${s.include_key}']))"
  ], ["true"])))

  role_assignments = var.assign_roles ? {
    for pair in setproduct(local.role_scopes, ["Reader", "Scheduled Patching Contributor"]) :
    "${pair[0]}|${pair[1]}" => { scope = pair[0], role = pair[1] }
  } : {}

  msi_auth = {
    type     = "ManagedServiceIdentity"
    audience = "https://management.azure.com"
  }
  arg_uri = "https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01"
}
