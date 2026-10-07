terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4, < 6"
    }
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.0"
    }
  }
}

# azurerm 5.0 no longer registers resource providers by default; register only what this needs.
# Works the same on azurerm 4.x.
provider "azurerm" {
  resource_provider_registrations = "none"
  resource_providers_to_register  = ["Microsoft.Maintenance", "Microsoft.Logic", "Microsoft.Insights"]
  features {}
}

variable "customer_acronym" {
  type    = string
  default = "sbp"
}

variable "environment" {
  type    = string
  default = "prd"
}

variable "workload" {
  type    = string
  default = "patching"
}

locals {
  # Every schedule installs the frozen snapshot plus the Datadog agent on Linux (not frozen, always the
  # newest version). To freeze the agent per week instead, drop this extra and let the snapshot pick it up
  # (it is classified Other, so keep Other in the Linux snapshot filter below). snapshot_managed = true defaults the classifications to [] (Linux) and ["Definition"]
  # (Windows, Defender platform updates), so nothing else is installed.
  install_patches = {
    linux = { package_names_mask_to_include = ["datadog-agent=*"] }
  }
}

# The team setup: three weekly patch groups on Monday evening, Linux and Windows mixed per group.
module "patching" {
  source = "github.com/schubergphilis-ep/terraform-azure-mcaf-update-management"

  resource_group_name = "rg-${var.customer_acronym}${var.environment}-${var.workload}"
  location            = "westeurope"

  maintenance_configurations = {
    weekly1900 = {
      name             = "${var.customer_acronym}${var.environment}-${var.workload}-weekly-1900"
      snapshot_managed = true
      window           = { start_date_time = "2026-01-05 19:00", recur_every = "1Week Monday" }
      assignments      = { patchgroup1 = { tag_values = ["patchgroup1"] } }
      install_patches  = local.install_patches
    }
    weekly2100 = {
      name             = "${var.customer_acronym}${var.environment}-${var.workload}-weekly-2100"
      snapshot_managed = true
      window           = { start_date_time = "2026-01-05 21:00", recur_every = "1Week Monday" }
      assignments      = { patchgroup2 = { tag_values = ["patchgroup2"] } }
      install_patches  = local.install_patches
    }
    weekly2300 = {
      name             = "${var.customer_acronym}${var.environment}-${var.workload}-weekly-2300"
      snapshot_managed = true
      window           = { start_date_time = "2026-01-05 23:00", recur_every = "1Week Monday" }
      assignments      = { patchgroup3 = { tag_values = ["patchgroup3"] } }
      install_patches  = local.install_patches
    }
  }

  tags = { workload = var.workload }
}

resource "azurerm_monitor_action_group" "patching" {
  name                = "ag-${var.workload}-snapshot"
  resource_group_name = module.patching.resource_group_name
  short_name          = "patchsnap"

  email_receiver {
    name          = "operations"
    email_address = "operations@example.com"
  }
}

# One snapshot for the whole landing zone: every subscription under the management group, minus the
# excluded ones. Monday 07:00 is before all three patch groups, so they install the same list.
module "update_snapshot" {
  source = "../.."

  resource_group_name = module.patching.resource_group_name

  management_group_ids     = ["mg-landingzones"]
  exclude_subscription_ids = ["11111111-1111-1111-1111-111111111111"] # e.g. a sandbox

  # Or per subscription instead of a management group:
  #   subscription_ids = ["00000000-0000-0000-0000-000000000000"]

  schedule = {
    cadence = "weekly"
    weekday = "Monday"
    hour    = 7
  }

  # Only freeze critical and security updates. Leave out to freeze everything the assessment reports.
  operating_systems = {
    windows = { classifications = ["Critical", "Security"] }
    linux   = { classifications = ["Critical", "Security"] }
  }

  failed_run_alert = { action_group_id = azurerm_monitor_action_group.patching.id }

  tags = { workload = var.workload }
}

# Monthly alternative: snapshot on the Wednesday after Patch Tuesday.
#   schedule = { cadence = "monthly", patch_tuesday_offset_days = 1, hour = 6 }
