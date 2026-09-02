package policy

import rego.v1

pass_plan := {
  "resource_changes": [
    {
      "address": "azurerm_resource_group.good",
      "mode": "managed",
      "type": "azurerm_resource_group",
      "name": "good",
      "change": {
        "actions": ["create"],
        "after": {
          "tags": {
            "owner": "platform",
            "created-by": "pipeline",
            "cost-center": "cc-1",
            "environment": "prod",
            "function": "app",
            "service": "nile",
            "repo": "org/repo",
            "applicationname": "demo",
            "name": "rg-demo",
            "notificationdistlist": "ops@example.com",
            "ssp": "ssp-1",
            "trproductid": "tr-1",
            "apmid": "apm-1"
          }
        }
      }
    },
    {
      "address": "google_storage_bucket.good",
      "mode": "managed",
      "type": "google_storage_bucket",
      "name": "good",
      "change": {
        "actions": ["create"],
        "after": {
          "labels": {
            "owner": "platform",
            "created_by": "pipeline",
            "cost_center": "cc-1",
            "environment": "prod",
            "function": "app",
            "service": "nile",
            "repo": "org/repo",
            "application_name": "demo",
            "name": "bucket-demo",
            "notification_distlist": "ops-team",
            "ssp": "ssp-1",
            "tr_product_id": "tr-1",
            "apm_id": "apm-1"
          }
        }
      }
    }
  ]
}

fail_plan := {
  "resource_changes": [
    {
      "address": "azurerm_resource_group.bad",
      "mode": "managed",
      "type": "azurerm_resource_group",
      "name": "bad",
      "change": {
        "actions": ["create"],
        "after": {
          "tags": {
            "owner": "platform",
            "created-by": "pipeline",
            "cost-center": "cc-1",
            "environment": "prod",
            "function": "app",
            "service": "nile",
            "repo": "org/repo",
            "applicationname": "demo",
            "name": "rg-demo",
            "notificationdistlist": "ops@example.com",
            "ssp": "ssp-1",
            "trproductid": "",
            "apmid": "apm-1"
          }
        }
      }
    },
    {
      "address": "google_storage_bucket.bad",
      "mode": "managed",
      "type": "google_storage_bucket",
      "name": "bad",
      "change": {
        "actions": ["create"],
        "after": {
          "labels": {
            "owner": "platform",
            "created_by": "pipeline",
            "cost_center": "cc-1",
            "environment": "prod",
            "function": "app",
            "service": "nile",
            "repo": "org/repo",
            "application_name": "demo",
            "name": "bucket-demo",
            "notification_distlist": "",
            "ssp": "ssp-1",
            "tr_product_id": "tr-1",
            "apm_id": "apm-1"
          }
        }
      }
    }
  ]
}

test_pass_no_deny if {
  count(deny) == 0 with input as pass_plan
}

test_fail_has_deny if {
  count(deny) > 0 with input as fail_plan
}
