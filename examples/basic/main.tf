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

data "azurerm_client_config" "current" {}

# Defaults: one Logic App that takes the Windows and Linux snapshot every Monday at 07:00
# and update every maintenance configuration tagged aum-snapshot = managed in this subscription.
module "update_snapshot" {
  source = "../.."

  resource_group_name = "rg-update-snapshot"
  subscription_ids    = [data.azurerm_client_config.current.subscription_id]
}
