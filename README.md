# terraform-azure-mcaf-update-management-snapshot

Freeze Azure Update Manager patches in a weekly or monthly snapshot so every DTAP stage installs the same updates.

This Terraform module freezes the pending Azure Update Manager updates at a fixed moment and writes that list into
maintenance configurations, so every stage (test, acceptance, prod) installs exactly the same updates, even when
Microsoft releases something new in between.

It pairs with [terraform-azure-mcaf-update-management](https://github.com/schubergphilis-ep/terraform-azure-mcaf-update-management):
set `snapshot_managed = true` on a maintenance configuration there, and this module keeps its include list up to date.

## How it works

One Logic App handles Windows and Linux. At the scheduled moment it:

1. Checks that machines in scope (`management_group_ids` or `subscription_ids`, minus `exclude_subscription_ids`)
   have an Azure Update Manager assessment from the last 48 hours. If none do, the run fails and every include list
   stays unchanged: missing data must not look like "nothing to patch".
2. Reads the pending updates from the assessment data in Azure Resource Graph. Windows yields KB numbers (Defender
   definition updates excluded), Linux yields `name=version` package masks.
3. Finds every maintenance configuration tagged `aum-snapshot = managed` in the same scope.
4. Writes, in one PATCH per configuration, the snapshot plus the configuration's `aum-snapshot-<os>-extras` tag
   (for example `datadog-agent=*`) into the include list of each OS block the configuration has. Classifications,
   excludes and reboot setting stay as the owner set them, and no OS block is added.
5. Reads the configuration back and retries up to five times if the write did not persist.

**No pending updates.** When an OS has nothing pending, its include list becomes empty: this stage installs nothing
new for that OS this time. An empty include list does not mean "install everything": Azure Update Manager installs
the classifications *plus* the include list. With the snapshot defaults of terraform-azure-mcaf-update-management
that is nothing on Linux and only Defender platform updates on Windows. A block without classifications gets a
never-matching placeholder instead of an empty list, because the Maintenance API rejects a block with neither.

The maintenance configurations keep their own schedules. Every window after the snapshot moment installs the frozen
list until the next snapshot.

```text
Monday 07:00  snapshot (Windows and Linux)
Monday 19:00  test window             Thursday 19:00  prod window    -> same list
next Monday   new snapshot
```

## Usage

Together with terraform-azure-mcaf-update-management: set `snapshot_managed = true` on the maintenance
configurations there, and point this module at the same resource group and subscription.

```hcl
module "patching" {
  source = "github.com/schubergphilis-ep/terraform-azure-mcaf-update-management"
  # ... maintenance_configurations with snapshot_managed = true
}

module "update_snapshot" {
  source = "github.com/schubergphilis-ep/terraform-azure-mcaf-update-management-snapshot"

  resource_group_name = module.patching.resource_group_name
  subscription_ids    = ["00000000-0000-0000-0000-000000000000"]
}
```

Defaults: one Logic App, weekly on Monday 07:00 (W. Europe Standard Time), Windows and Linux, everything the assessment reports
except Defender definition updates, no alert.

### Scope

Deploy the snapshot once, high up, and give it the scope it serves:

| Input | Effect |
|---|---|
| `subscription_ids` | Read assessment data from and update configurations in these subscriptions. Roles are assigned per subscription. |
| `management_group_ids` | Same for every subscription below these management groups, including ones added later. Roles are assigned on the management group. |
| `exclude_subscription_ids` | Leave these out of both. Role assignments on a management group still apply to them. |

Set exactly one of `subscription_ids` and `management_group_ids`. The identity needs Reader and Scheduled Patching
Contributor on the scope; the module assigns both unless `assign_roles = false`.

### Schedule

| Cadence | Settings | Runs |
|---|---|---|
| `weekly` (default) | `weekday`, `hour`, `minute` | Every week on that day and time |
| `monthly` | `patch_tuesday_offset_days`, `hour`, `minute` | Once a month, Patch Tuesday plus the offset (1 = Wednesday after, 6 = Monday after) |

Every maintenance window that should install the
new list must start after the snapshot moment; the defaults (Monday 07:00) come before the Monday-evening and
Wednesday windows of terraform-azure-mcaf-update-management.

### Alert

Set `failed_run_alert = { action_group_id = ... }` to get a metric alert on failed runs. A run fails when there is no
recent assessment data, a write does not persist after five attempts, or permissions are missing. The include lists stay unchanged then, so
the stages keep installing the previous list until someone acts.

See [examples/basic](examples/basic) and [examples/advanced](examples/advanced). The advanced example is a team setup:
three weekly patch groups from terraform-azure-mcaf-update-management, a management group with an excluded
subscription, only critical and security updates frozen, and an alert.

## Provider versions

Works with azurerm 4.x and 5.x. azurerm 5.0 no longer registers resource providers by default; make sure
`Microsoft.Maintenance`, `Microsoft.Logic` and, for alerts, `Microsoft.Insights` are registered, for example with
`resource_providers_to_register` in the provider block as shown in the examples.

## Things to know

- **Two kinds of classifications.** `operating_systems.<os>.classifications` here decides what goes into the
  frozen list, for example only critical and security. `classifications_to_include` on the maintenance
  configuration decides what is installed on top of it; with `snapshot_managed = true` that defaults to `[]` (Linux)
  and `["Definition"]` (Windows), so only the snapshot is installed. Setting `Critical` or `Security` there
  explicitly shows a warning, because it installs updates that were never part of the snapshot.
- **Defender.** Security intelligence (signature) updates are fetched by Defender itself. Platform and engine updates
  (for example KB4052623) come through Windows Update and need the `Definition` classification on the schedule.
- **Agents such as Datadog.** Two options, both verified:
  - Let the snapshot freeze it. When the vendor repository is configured on the machines, the assessment reports a
    newer agent as a pending update (classification `Other`), and the snapshot pins it as
    `datadog-agent=1:7.84.1-1`, identical for every stage. Do not filter Linux to `Critical`/`Security` only, or add
    `Other`. First installs still belong in VM provisioning.
  - Or add it as an extra on the maintenance configuration: `datadog-agent=*` (always the newest, not frozen) or a
    fixed `datadog-agent=1:7.84.0-1` (exact apt version including the epoch, bumped by hand).
  Azure Update Manager installs exactly the pinned version, not the newest available. On Windows the Datadog agent
  does not come through Windows Update, so neither option applies there.
- **Assessment scope.** The snapshot is built from all machines in scope. Machines need periodic assessment and
  patch orchestration set to Customer Managed Schedules.
- **One snapshot per scope.** Two instances of this module over the same subscription write the same
  configurations. Use separate subscriptions, or excludes, for separate cadences.
- **Superseded updates.** If Microsoft supersedes a frozen KB before a later stage runs, Azure Update Manager is
  expected to skip it rather than install something newer. This is not yet verified.

## Known limitations

### Large environments: more than 1000 pending items

Not handled yet. Relevant when many Linux distributions or versions share one snapshot scope.

- **Resource Graph returns at most 1000 rows per query page.** The pending-update queries return one row per
  unique KB or `name=version`, without paging. Everything after row 1000 is silently dropped, so the snapshot
  would miss updates. Linux is the likely case: every distribution and release has its own package versions, so
  Ubuntu 22.04 and 24.04, Debian and RHEL together quickly reach thousands of unique masks. Windows (a handful of
  KBs per month) and the target configurations (one row per maintenance configuration) are unlikely to get there.
- **The size of an include list is unknown.** Microsoft does not document how many items `kbNumbersToInclude` /
  `packageNameMasksToInclude` can hold, or how Azure Update Manager behaves with very large lists on a machine.
  This may be the tighter limit, and solving the paging alone does not address it.

Possible approach, in order:

1. Measure the include-list limit: PATCH a test configuration with growing lists (500, 1000, 2500, 5000) and run
   one installation with a large list.
2. Aggregate in the queries (`summarize items = array_sort_asc(make_set(item))`) so each query returns a single
   row, which never hits the page limit. Fail the run with a clear message when a list exceeds the measured
   limit, instead of truncating it.
3. Only if the limit turns out too low: split per distribution, with a distribution filter in the snapshot and
   patch groups per distribution.

Current sandbox scale: 86 Linux masks and 1 Windows KB.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9 |
| <a name="requirement_azapi"></a> [azapi](#requirement\_azapi) | ~> 2.0 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | >= 4, < 6 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_azapi"></a> [azapi](#provider\_azapi) | ~> 2.0 |
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | >= 4, < 6 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [azapi_resource.snapshot](https://registry.terraform.io/providers/azure/azapi/latest/docs/resources/resource) | resource |
| [azurerm_monitor_metric_alert.runs_failed](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_metric_alert) | resource |
| [azurerm_role_assignment.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_resource_group.this](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/resource_group) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_resource_group_name"></a> [resource\_group\_name](#input\_resource\_group\_name) | The name of the existing resource group in which the Logic Apps are created. | `string` | n/a | yes |
| <a name="input_assign_roles"></a> [assign\_roles](#input\_assign\_roles) | Assign Reader and Scheduled Patching Contributor to the Logic App identity on every entry of `management_group_ids` or `subscription_ids`. Disable when roles are managed elsewhere; the principal ID is in the `principal_id` output. | `bool` | `true` | no |
| <a name="input_exclude_subscription_ids"></a> [exclude\_subscription\_ids](#input\_exclude\_subscription\_ids) | Subscriptions to leave out, typically under one of `management_group_ids`. Their assessment data is ignored and their maintenance configurations are not touched. The role assignments on a management group still apply to them. | `list(string)` | `[]` | no |
| <a name="input_failed_run_alert"></a> [failed\_run\_alert](#input\_failed\_run\_alert) | Alert when a snapshot run fails (no recent assessment data, write not persisted, missing permissions): a metric<br/>alert on the Logic App's `RunsFailed`. No alert when null. An object rather than a plain ID, so the alert can be planned while<br/>the action group is created in the same apply.<br/><br/>- `action_group_id` - (Required) Action group to notify.<br/>- `severity` - (Optional) Alert severity 0-4. Defaults to `2`. | <pre>object({<br/>    action_group_id = string<br/>    severity        = optional(number, 2)<br/>  })</pre> | `null` | no |
| <a name="input_location"></a> [location](#input\_location) | The location of the Logic Apps. Defaults to the location of the resource group. | `string` | `null` | no |
| <a name="input_management_group_ids"></a> [management\_group\_ids](#input\_management\_group\_ids) | Management groups the snapshot covers: every subscription below them is read and its maintenance configurations tagged `aum-snapshot = managed` are updated. Use this or `subscription_ids`, not both. | `list(string)` | `[]` | no |
| <a name="input_name"></a> [name](#input\_name) | Name of the Logic App. | `string` | `"update-snapshot"` | no |
| <a name="input_operating_systems"></a> [operating\_systems](#input\_operating\_systems) | Which operating systems the snapshot handles, and which pending updates go into the frozen list.<br/><br/>- `windows.enabled` / `linux.enabled` - (Optional) Snapshot this OS. A disabled OS block on a maintenance configuration is left untouched. Defaults to `true`.<br/>- `windows.classifications` - (Optional) Only freeze these classifications. Empty means everything the assessment reports. Definition updates are never frozen. Possible values: Critical, Security, UpdateRollup, FeaturePack, ServicePack, Tools, Updates.<br/>- `linux.classifications` - (Optional) Same for Linux. Possible values: Critical, Security, Other. | <pre>object({<br/>    windows = optional(object({<br/>      enabled         = optional(bool, true)<br/>      classifications = optional(list(string), [])<br/>    }), {})<br/>    linux = optional(object({<br/>      enabled         = optional(bool, true)<br/>      classifications = optional(list(string), [])<br/>    }), {})<br/>  })</pre> | `{}` | no |
| <a name="input_schedule"></a> [schedule](#input\_schedule) | When the snapshot is taken.<br/><br/>- `cadence` - (Optional) `weekly` or `monthly`. Defaults to `weekly`.<br/>- `weekday` - (Optional) Weekday for `weekly`. Defaults to `Monday`.<br/>- `patch_tuesday_offset_days` - (Optional) For `monthly`: days after Patch Tuesday (second Tuesday), 0-17. 0 is Patch Tuesday itself, 1 the Wednesday after, 6 the Monday after. The weekday follows from the offset. Defaults to `6`.<br/>- `hour` - (Optional) Hour, 0-23. Defaults to `7`.<br/>- `minute` - (Optional) Minute, 0-59. Defaults to `0`.<br/>- `time_zone` - (Optional) Windows time zone name. Defaults to `W. Europe Standard Time`.<br/><br/>Every maintenance window that should use the new list must start after this moment. | <pre>object({<br/>    cadence                   = optional(string, "weekly")<br/>    weekday                   = optional(string, "Monday")<br/>    patch_tuesday_offset_days = optional(number, 6)<br/>    hour                      = optional(number, 7)<br/>    minute                    = optional(number, 0)<br/>    time_zone                 = optional(string, "W. Europe Standard Time")<br/>  })</pre> | `{}` | no |
| <a name="input_subscription_ids"></a> [subscription\_ids](#input\_subscription\_ids) | Subscriptions the snapshot covers. Use this or `management_group_ids`, not both. | `list(string)` | `[]` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | A mapping of tags to assign to the resources. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_alert_id"></a> [alert\_id](#output\_alert\_id) | ID of the failed-run metric alert. Null when `failed_run_alert` is null. |
| <a name="output_logic_app_id"></a> [logic\_app\_id](#output\_logic\_app\_id) | Resource ID of the snapshot Logic App. |
| <a name="output_principal_id"></a> [principal\_id](#output\_principal\_id) | Principal ID of the Logic App's system-assigned identity. Use it when `assign_roles = false`. |
| <a name="output_schedule"></a> [schedule](#output\_schedule) | Effective snapshot moment. |
| <a name="output_target_tag"></a> [target\_tag](#output\_target\_tag) | Tag that marks a maintenance configuration as managed by this snapshot. Set by terraform-azure-mcaf-update-management when `snapshot_managed = true`. |
<!-- END_TF_DOCS -->

## License

**Copyright:** Schuberg Philis

```text
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```
