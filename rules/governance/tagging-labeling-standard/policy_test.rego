package policy

import rego.v1

pass_plan := {
  "resource_changes": [
    {
      "address": "azurerm_resource_group.ok",
      "mode": "managed",
      "type": "azurerm_resource_group",
      "name": "ok",
      "change": {
        "actions": ["create"],
        "after": {
          "tags": {
            "owner": "platformengineering",
            "created-by": "pipeline-sp",
            "cost-center": "cc-100",
            "environment": "dev",
            "function": "app-hosting",
            "service": "nile",
            "repo": "walmart-stackgen/nile-factory",
            "applicationname": "projectnile",
            "name": "rg-ok",
            "notificationdistlist": "ops@example.com",
            "ssp": "ssp-001",
            "trproductid": "tr-001",
            "apmid": "apm-001"
          }
        }
      }
    },
    {
      "address": "google_compute_instance.ok",
      "mode": "managed",
      "type": "google_compute_instance",
      "name": "ok",
      "change": {
        "actions": ["create"],
        "after": {
          "labels": {
            "owner": "platformengineering",
            "created_by": "pipeline-sa",
            "cost_center": "cc-200",
            "environment": "prod",
            "function": "api",
            "service": "nile",
            "repo": "walmart-stackgen/nile-factory",
            "application_name": "projectnile",
            "name": "vm-ok",
            "notification_distlist": "ops-team",
            "ssp": "ssp-002",
            "tr_product_id": "tr-002",
            "apm_id": "apm-002"
          }
        }
      }
    }
  ]
}

fail_plan := {
  "resource_changes": [
    {
      "address": "azurerm_storage_account.bad",
      "mode": "managed",
      "type": "azurerm_storage_account",
      "name": "bad",
      "change": {
        "actions": ["create"],
        "after": {
          "tags": {
            "owner": "TBD",
            "created-by": "pipeline-sp",
            "cost-center": "cc-100",
            "environment": "qa",
            "function": "storage",
            "service": "nile",
            "repo": "",
            "applicationname": "projectnile",
            "name": "stbad",
            "notificationdistlist": "ops@example.com",
            "ssp": "ssp-001",
            "trproductid": "tr-001"
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
        "actions": ["update"],
        "after": {
          "labels": {
            "owner": "platformengineering",
            "created_by": "placeholder",
            "cost_center": "cc-200",
            "environment": "production",
            "function": "data",
            "service": "nile",
            "repo": "walmart-stackgen/nile-factory",
            "application_name": "projectnile",
            "name": "bucketbad",
            "notification_distlist": "ops-team",
            "ssp": "ssp-002",
            "tr_product_id": "tr-002",
            "apm_id": ""
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
