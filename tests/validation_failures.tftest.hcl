# Invalid input must be rejected.

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

run "bad_cadence" {
  command = plan

  variables {
    schedule = { cadence = "daily" }
  }

  expect_failures = [
    var.schedule,
  ]
}

run "bad_weekday" {
  command = plan

  variables {
    schedule = { weekday = "Maandag" }
  }

  expect_failures = [
    var.schedule,
  ]
}

run "offset_out_of_range" {
  command = plan

  variables {
    schedule = { cadence = "monthly", patch_tuesday_offset_days = 18 }
  }

  expect_failures = [
    var.schedule,
  ]
}

run "bad_windows_classification" {
  command = plan

  variables {
    operating_systems = { windows = { classifications = ["Definition"] } }
  }

  expect_failures = [
    var.operating_systems,
  ]
}

run "bad_linux_classification" {
  command = plan

  variables {
    operating_systems = { linux = { classifications = ["Updates"] } }
  }

  expect_failures = [
    var.operating_systems,
  ]
}

run "nothing_enabled" {
  command = plan

  variables {
    operating_systems = { windows = { enabled = false }, linux = { enabled = false } }
  }

  expect_failures = [
    var.operating_systems,
  ]
}

run "no_scope" {
  command = plan

  variables {
    subscription_ids     = []
    management_group_ids = []
  }

  expect_failures = [
    var.subscription_ids,
  ]
}

run "bad_subscription" {
  command = plan

  variables {
    subscription_ids = ["not-a-guid"]
  }

  expect_failures = [
    var.subscription_ids,
  ]
}

run "bad_name" {
  command = plan

  variables {
    name = "-snapshot"
  }

  expect_failures = [
    var.name,
  ]
}

run "both_scopes" {
  command = plan

  variables {
    management_group_ids = ["mg-landingzones"]
  }

  expect_failures = [
    var.subscription_ids,
  ]
}

run "bad_exclude" {
  command = plan

  variables {
    exclude_subscription_ids = ["nope"]
  }

  expect_failures = [
    var.exclude_subscription_ids,
  ]
}
