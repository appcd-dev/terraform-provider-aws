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
						"owner": "platform-team",
						"created-by": "pipeline",
						"cost-center": "cc-123",
						"environment": "prod",
						"function": "shared-services",
						"service": "nile",
						"repo": "Walmart-StackGen/Nile-Factory",
						"applicationname": "nile-core",
						"name": "rg-nile-prod",
						"notificationdistlist": "ops@example.com",
						"ssp": "ssp-001",
						"trproductid": "tr-001",
						"apmid": "apm-001",
					},
				},
			},
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
						"owner": "platform-team",
						"created_by": "pipeline",
						"cost_center": "cc-123",
						"environment": "prod",
						"function": "shared-services",
						"service": "nile",
						"repo": "Walmart-StackGen/Nile-Factory",
						"application_name": "nile-core",
						"name": "bucket-nile-prod",
						"notification_distlist": "ops@example.com",
						"ssp": "ssp-001",
						"tr_product_id": "tr-001",
						"apm_id": "apm-001",
					},
				},
			},
		},
		# Label-incapable VPC types must not trip PRG-002.
		{
			"address": "google_compute_network.vpc",
			"mode": "managed",
			"type": "google_compute_network",
			"name": "vpc",
			"change": {
				"actions": ["create"],
				"after": {"name": "vpc-nile"},
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
					"tags": {
						"owner": "unknown",
						"created-by": "pipeline",
					},
				},
			},
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
						"owner": "platform-team",
						"created_by": "pipeline",
						"cost_center": "cc-123",
						"environment": "TBD",
						"function": "shared-services",
						"service": "nile",
						"repo": "",
						"application_name": "nile-core",
						"name": "bucket-nile-prod",
						"notification_distlist": "ops@example.com",
						"ssp": "ssp-001",
						"tr_product_id": "tr-001",
						"apm_id": "apm-001",
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

test_network_without_labels_exempt if {
	count(deny) == 0 with input as {"resource_changes": [{
		"address": "google_compute_network.bare",
		"mode": "managed",
		"type": "google_compute_network",
		"name": "bare",
		"change": {"actions": ["create"], "after": {"name": "vpc"}},
	}]}
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
