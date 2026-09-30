package policy

import rego.v1

pass_plan := {
	"resource_changes": [
		{
			"address": "azurerm_linux_web_app.good",
			"mode": "managed",
			"type": "azurerm_linux_web_app",
			"name": "good",
			"change": {
				"actions": ["create"],
				"after": {
					"tags": {
						"owner": "platform",
						"created-by": "ci",
						"cost-center": "cc-1",
						"environment": "dev",
						"function": "app",
						"service": "nile",
						"repo": "org/repo",
						"applicationname": "demo",
						"name": "good-app",
						"notificationdistlist": "ops@example.com",
						"ssp": "ssp-1",
						"trproductid": "tr-1",
						"apmid": "apm-1",
					},
					"https_only": true,
					"identity": {
						"type": "SystemAssigned",
					},
				},
			},
		},
		{
			"address": "azurerm_network_interface.good",
			"mode": "managed",
			"type": "azurerm_network_interface",
			"name": "good",
			"change": {
				"actions": ["create"],
				"after": {
					"tags": {
						"owner": "platform",
						"created-by": "ci",
						"cost-center": "cc-1",
						"environment": "dev",
						"function": "net",
						"service": "nile",
						"repo": "org/repo",
						"applicationname": "demo",
						"name": "nic-good",
						"notificationdistlist": "ops@example.com",
						"ssp": "ssp-1",
						"trproductid": "tr-1",
						"apmid": "apm-1",
					},
					"ip_configuration": [
						{
							"name": "internal",
							"private_ip_address_allocation": "Dynamic",
						},
					],
				},
			},
		},
		{
			"address": "azurerm_storage_account.good",
			"mode": "managed",
			"type": "azurerm_storage_account",
			"name": "good",
			"change": {
				"actions": ["create"],
				"after": {
					"tags": {
						"owner": "platform",
						"created-by": "ci",
						"cost-center": "cc-1",
						"environment": "dev",
						"function": "storage",
						"service": "nile",
						"repo": "org/repo",
						"applicationname": "demo",
						"name": "stgood",
						"notificationdistlist": "ops@example.com",
						"ssp": "ssp-1",
						"trproductid": "tr-1",
						"apmid": "apm-1",
					},
					"https_traffic_only_enabled": true,
				},
			},
		},
		{
			"address": "azurerm_key_vault.good",
			"mode": "managed",
			"type": "azurerm_key_vault",
			"name": "good",
			"change": {
				"actions": ["create"],
				"after": {
					"tags": {
						"owner": "platform",
						"created-by": "ci",
						"cost-center": "cc-1",
						"environment": "dev",
						"function": "security",
						"service": "nile",
						"repo": "org/repo",
						"applicationname": "demo",
						"name": "kv-good",
						"notificationdistlist": "ops@example.com",
						"ssp": "ssp-1",
						"trproductid": "tr-1",
						"apmid": "apm-1",
					},
					"soft_delete_retention_days": 7,
					"purge_protection_enabled": true,
				},
			},
		},
		{
			"address": "google_compute_instance.good",
			"mode": "managed",
			"type": "google_compute_instance",
			"name": "good",
			"change": {
				"actions": ["create"],
				"after": {
					"zone": "us-central1-a",
					"labels": {
						"owner": "platform",
						"created_by": "ci",
						"cost_center": "cc-1",
						"environment": "dev",
						"function": "app",
						"service": "nile",
						"repo": "org-repo",
						"application_name": "demo",
						"name": "vm-good",
						"notification_distlist": "ops",
						"ssp": "ssp-1",
						"tr_product_id": "tr-1",
						"apm_id": "apm-1",
					},
					"network_interface": [
						{
							"subnetwork": "default",
						},
					],
				},
			},
		},
	],
}

fail_plan := {
	"resource_changes": [
		{
			"address": "azurerm_linux_web_app.bad",
			"mode": "managed",
			"type": "azurerm_linux_web_app",
			"name": "bad",
			"change": {
				"actions": ["create"],
				"after": {
					"tags": {
						"owner": "",
					},
					"https_only": false,
				},
			},
		},
		{
			"address": "azurerm_network_interface.bad",
			"mode": "managed",
			"type": "azurerm_network_interface",
			"name": "bad",
			"change": {
				"actions": ["create"],
				"after": {
					"tags": {
						"owner": "platform",
						"created-by": "ci",
						"cost-center": "cc-1",
						"environment": "dev",
						"function": "net",
						"service": "nile",
						"repo": "org/repo",
						"applicationname": "demo",
						"name": "nic-bad",
						"notificationdistlist": "ops@example.com",
						"ssp": "ssp-1",
						"trproductid": "tr-1",
						"apmid": "apm-1",
					},
					"ip_configuration": [
						{
							"name": "public",
							"public_ip_address_id": "/subscriptions/test/resourceGroups/rg/providers/Microsoft.Network/publicIPAddresses/pip1",
						},
					],
				},
			},
		},
		{
			"address": "azurerm_storage_account.bad",
			"mode": "managed",
			"type": "azurerm_storage_account",
			"name": "bad",
			"change": {
				"actions": ["create"],
				"after": {
					"tags": {
						"owner": "platform",
						"created-by": "ci",
						"cost-center": "cc-1",
						"environment": "dev",
						"function": "storage",
						"service": "nile",
						"repo": "org/repo",
						"applicationname": "demo",
						"name": "stbad",
						"notificationdistlist": "ops@example.com",
						"ssp": "ssp-1",
						"trproductid": "tr-1",
						"apmid": "apm-1",
					},
					"https_traffic_only_enabled": false,
				},
			},
		},
		{
			"address": "azurerm_key_vault.bad",
			"mode": "managed",
			"type": "azurerm_key_vault",
			"name": "bad",
			"change": {
				"actions": ["create"],
				"after": {
					"tags": {
						"owner": "platform",
						"created-by": "ci",
						"cost-center": "cc-1",
						"environment": "dev",
						"function": "security",
						"service": "nile",
						"repo": "org/repo",
						"applicationname": "demo",
						"name": "kv-bad",
						"notificationdistlist": "ops@example.com",
						"ssp": "ssp-1",
						"trproductid": "tr-1",
						"apmid": "apm-1",
					},
					"soft_delete_retention_days": 0,
					"purge_protection_enabled": false,
				},
			},
		},
		{
			"address": "google_compute_instance.bad",
			"mode": "managed",
			"type": "google_compute_instance",
			"name": "bad",
			"change": {
				"actions": ["create"],
				"after": {
					"zone": "europe-west1-b",
					"labels": {
						"owner": "platform",
					},
					"network_interface": [
						{
							"subnetwork": "default",
							"access_config": [
								{
									"nat_ip": "34.1.2.3",
								},
							],
						},
					],
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

gke_metadata_plan := {
	"resource_changes": [
		{
			"address": "google_container_cluster.this",
			"mode": "managed",
			"type": "google_container_cluster",
			"name": "this",
			"change": {"actions": ["create"], "after": {
				"location": "us-central1",
				"resource_labels": {
					"owner": "platformengineering",
					"created_by": "stackgen-aws-migrator",
					"cost_center": "cc-migration",
					"environment": "dev",
					"function": "migration",
					"service": "nile",
					"repo": "walmart-stackgen-nile-factory",
					"application_name": "projectnile",
					"name": "nile-migration",
					"notification_distlist": "nile-ops",
					"ssp": "ssp-migration",
					"tr_product_id": "tr-migration",
					"apm_id": "apm-migration"
				},
			}},
		},
		{
			"address": "google_container_node_pool.system",
			"mode": "managed",
			"type": "google_container_node_pool",
			"name": "system",
			"change": {"actions": ["create"], "after": {
				"location": "us-central1",
				"node_config": [{"labels": {
					"owner": "platformengineering",
					"created_by": "stackgen-aws-migrator",
					"cost_center": "cc-migration",
					"environment": "dev",
					"function": "migration",
					"service": "nile",
					"repo": "walmart-stackgen-nile-factory",
					"application_name": "projectnile",
					"name": "nile-migration",
					"notification_distlist": "nile-ops",
					"ssp": "ssp-migration",
					"tr_product_id": "tr-migration",
					"apm_id": "apm-migration"
				}}],
			}},
		},
	],
}

test_gke_schema_specific_labels_satisfy_metadata_controls if {
	count(deny) == 0 with input as gke_metadata_plan
}

test_gke_missing_label_is_still_denied if {
	plan := {"resource_changes": [{
		"address": "google_container_cluster.incomplete",
		"mode": "managed",
		"type": "google_container_cluster",
		"name": "incomplete",
		"change": {"actions": ["create"], "after": {
			"resource_labels": {"owner": "platformengineering"},
		}},
	}]}
	count(deny) > 0 with input as plan
}
