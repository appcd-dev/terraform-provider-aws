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
					"name": "rg-ok",
					"tags": {
						"owner": "platform",
						"cost-center": "cc-1",
						"repo": "org/repo",
						"service": "nile",
						"apmid": "apm-1",
					},
				},
			},
		},
		{
			"address": "google_storage_bucket.ok",
			"mode": "managed",
			"type": "google_storage_bucket",
			"name": "ok",
			"change": {
				"actions": ["update"],
				"after": {
					"name": "bucket-ok",
					"labels": {
						"owner": "platform",
						"cost_center": "cc-1",
						"repo": "org/repo",
						"service": "nile",
						"apm_id": "apm-1",
					},
				},
			},
		},
	],
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
					"name": "rg-bad",
					"tags": {
						"owner": "platform",
						"cost-center": "",
						"repo": "org/repo",
					},
				},
			},
		},
	],
}

test_pass_no_deny if {
	count(deny) == 0 with input as pass_plan
}

test_fail_has_deny if {
	count(deny) > 0 with input as fail_plan
}
