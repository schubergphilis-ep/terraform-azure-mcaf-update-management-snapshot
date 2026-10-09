# Shared mock defaults for the azurerm provider, so mocked values pass resource ID validation.

mock_data "azurerm_resource_group" {
  defaults = {
    id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg"
    location = "westeurope"
  }
}

mock_resource "azurerm_monitor_metric_alert" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Insights/metricAlerts/test"
  }
}
