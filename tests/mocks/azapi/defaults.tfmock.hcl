# Shared mock defaults for the azapi provider.

mock_resource "azapi_resource" {
  defaults = {
    id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Logic/workflows/test"
    identity = {
      type         = "SystemAssigned"
      principal_id = "11111111-1111-1111-1111-111111111111"
      tenant_id    = "22222222-2222-2222-2222-222222222222"
      identity_ids = []
    }
  }
}
