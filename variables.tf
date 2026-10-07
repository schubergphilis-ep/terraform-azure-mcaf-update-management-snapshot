variable "resource_group_name" {
  type        = string
  description = "The name of the existing resource group in which the Logic Apps are created."
  validation {
    condition     = length(var.resource_group_name) >= 1
    error_message = "resource_group_name cannot be empty."
  }
}

variable "location" {
  type        = string
  default     = null
  description = "The location of the Logic Apps. Defaults to the location of the resource group."
}

variable "name" {
  type        = string
  default     = "update-snapshot"
  description = "Name of the Logic App."
  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9-]{0,70}[A-Za-z0-9]$", var.name))
    error_message = "name must be 2-72 characters, alphanumeric and hyphens, and not start or end with a hyphen."
  }
}

variable "management_group_ids" {
  type        = list(string)
  default     = []
  description = "Management groups the snapshot covers: every subscription below them is read and its maintenance configurations tagged `aum-snapshot = managed` are updated. Use this or `subscription_ids`, not both."
}

variable "subscription_ids" {
  type        = list(string)
  default     = []
  description = "Subscriptions the snapshot covers. Use this or `management_group_ids`, not both."
  validation {
    condition     = alltrue([for id in var.subscription_ids : can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", id))])
    error_message = "subscription_ids must contain subscription UUIDs."
  }
  validation {
    condition     = (length(var.subscription_ids) > 0) != (length(var.management_group_ids) > 0)
    error_message = "Set exactly one of subscription_ids or management_group_ids."
  }
}

variable "exclude_subscription_ids" {
  type        = list(string)
  default     = []
  description = "Subscriptions to leave out, typically under one of `management_group_ids`. Their assessment data is ignored and their maintenance configurations are not touched. The role assignments on a management group still apply to them."
  validation {
    condition     = alltrue([for id in var.exclude_subscription_ids : can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", id))])
    error_message = "exclude_subscription_ids must contain subscription UUIDs."
  }
}

variable "schedule" {
  type = object({
    cadence                   = optional(string, "weekly")
    weekday                   = optional(string, "Monday")
    patch_tuesday_offset_days = optional(number, 6)
    hour                      = optional(number, 7)
    minute                    = optional(number, 0)
    time_zone                 = optional(string, "W. Europe Standard Time")
  })
  default     = {}
  description = <<DESCRIPTION
When the snapshot is taken.

- `cadence` - (Optional) `weekly` or `monthly`. Defaults to `weekly`.
- `weekday` - (Optional) Weekday for `weekly`. Defaults to `Monday`.
- `patch_tuesday_offset_days` - (Optional) For `monthly`: days after Patch Tuesday (second Tuesday), 0-17. 0 is Patch Tuesday itself, 1 the Wednesday after, 6 the Monday after. The weekday follows from the offset. Defaults to `6`.
- `hour` - (Optional) Hour, 0-23. Defaults to `7`.
- `minute` - (Optional) Minute, 0-59. Defaults to `0`.
- `time_zone` - (Optional) Windows time zone name. Defaults to `W. Europe Standard Time`.

Every maintenance window that should use the new list must start after this moment.
DESCRIPTION

  validation {
    condition     = contains(["weekly", "monthly"], var.schedule.cadence)
    error_message = "schedule.cadence must be weekly or monthly."
  }
  validation {
    condition     = contains(["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"], var.schedule.weekday)
    error_message = "schedule.weekday must be Monday..Sunday."
  }
  validation {
    condition     = var.schedule.patch_tuesday_offset_days >= 0 && var.schedule.patch_tuesday_offset_days <= 17 && floor(var.schedule.patch_tuesday_offset_days) == var.schedule.patch_tuesday_offset_days
    error_message = "schedule.patch_tuesday_offset_days must be a whole number between 0 and 17."
  }
  validation {
    condition     = var.schedule.hour >= 0 && var.schedule.hour <= 23 && var.schedule.minute >= 0 && var.schedule.minute <= 59
    error_message = "schedule.hour must be 0-23 and schedule.minute 0-59."
  }
}

variable "operating_systems" {
  type = object({
    windows = optional(object({
      enabled         = optional(bool, true)
      classifications = optional(list(string), [])
    }), {})
    linux = optional(object({
      enabled         = optional(bool, true)
      classifications = optional(list(string), [])
    }), {})
  })
  default     = {}
  description = <<DESCRIPTION
Which operating systems the snapshot handles, and which pending updates go into the frozen list.

- `windows.enabled` / `linux.enabled` - (Optional) Snapshot this OS. A disabled OS block on a maintenance configuration is left untouched. Defaults to `true`.
- `windows.classifications` - (Optional) Only freeze these classifications. Empty means everything the assessment reports. Definition updates are never frozen. Possible values: Critical, Security, UpdateRollup, FeaturePack, ServicePack, Tools, Updates.
- `linux.classifications` - (Optional) Same for Linux. Possible values: Critical, Security, Other.
DESCRIPTION

  validation {
    condition     = alltrue([for c in var.operating_systems.windows.classifications : contains(["Critical", "Security", "UpdateRollup", "FeaturePack", "ServicePack", "Tools", "Updates"], c)])
    error_message = "operating_systems.windows.classifications allows Critical, Security, UpdateRollup, FeaturePack, ServicePack, Tools, Updates."
  }
  validation {
    condition     = alltrue([for c in var.operating_systems.linux.classifications : contains(["Critical", "Security", "Other"], c)])
    error_message = "operating_systems.linux.classifications allows Critical, Security, Other."
  }
  validation {
    condition     = var.operating_systems.windows.enabled || var.operating_systems.linux.enabled
    error_message = "Enable at least one operating system."
  }
}

variable "assign_roles" {
  type        = bool
  default     = true
  description = "Assign Reader and Scheduled Patching Contributor to the Logic App identity on every entry of `management_group_ids` or `subscription_ids`. Disable when roles are managed elsewhere; the principal ID is in the `principal_id` output."
}

variable "failed_run_alert" {
  type = object({
    action_group_id = string
    severity        = optional(number, 2)
  })
  default     = null
  description = <<DESCRIPTION
Alert when a snapshot run fails (no recent assessment data, write not persisted, missing permissions): a metric
alert on the Logic App's `RunsFailed`. No alert when null. An object rather than a plain ID, so the alert can be planned while
the action group is created in the same apply.

- `action_group_id` - (Required) Action group to notify.
- `severity` - (Optional) Alert severity 0-4. Defaults to `2`.
DESCRIPTION
  validation {
    condition     = var.failed_run_alert == null || try(var.failed_run_alert.severity >= 0 && var.failed_run_alert.severity <= 4, false)
    error_message = "failed_run_alert.severity must be 0-4."
  }
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "A mapping of tags to assign to the resources."
}
