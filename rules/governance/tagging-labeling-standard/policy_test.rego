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
						"apmid": "apm-001",
					},
				},
			},
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
						"apm_id": "apm-002",
					},
				},
			},
		},
	],
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
						"trproductid": "tr-001",
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
						"apm_id": "",
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

# Network/firewall types have no labels attr — TAG-002 must not fire.
label_incapable_plan := {
	"resource_changes": [
		{
			"address": "google_compute_network.this",
			"mode": "managed",
			"type": "google_compute_network",
			"name": "this",
			"change": {
				"actions": ["create"],
				"after": {
					"name": "vpc-migration",
				},
			},
		},
		{
			"address": "google_compute_firewall.deny_ingress",
			"mode": "managed",
			"type": "google_compute_firewall",
			"name": "deny_ingress",
			"change": {
				"actions": ["create"],
				"after": {
					"name": "fw-deny",
					"network": "vpc-migration",
				},
			},
		},
		{
			"address": "google_logging_project_bucket_config.this",
			"mode": "managed",
			"type": "google_logging_project_bucket_config",
			"name": "this",
			"change": {"actions": ["create"], "after": {"bucket_id": "migration"}},
		},
		{
			"address": "google_bigtable_table.primary",
			"mode": "managed",
			"type": "google_bigtable_table",
			"name": "primary",
			"change": {"actions": ["create"], "after": {"name": "primary"}},
		},
	],
}

test_label_incapable_no_tag002 if {
	count(deny) == 0 with input as label_incapable_plan
}

test_sql_instance_user_labels_are_recognized if {
	plan := {
		"resource_changes": [
			{
				"address": "google_sql_database_instance.this",
				"mode": "managed",
				"type": "google_sql_database_instance",
				"name": "this",
				"change": {
					"actions": ["create"],
					"after": {"settings": [{"user_labels": {"owner": "team"}}]},
				},
			},
			{
				"address": "google_sql_database_instance.incomplete",
				"mode": "managed",
				"type": "google_sql_database_instance",
				"name": "incomplete",
				"change": {
					"actions": ["create"],
					"after": {"settings": [{"user_labels": {}}]},
				},
			},
		],
	}
	count(deny) == 25 with input as plan
}

test_sql_instance_user_labels_satisfy_tag002 if {
	plan := {
		"resource_changes": [
			{
				"address": "google_sql_database_instance.this",
				"mode": "managed",
				"type": "google_sql_database_instance",
				"name": "this",
				"change": {
					"actions": ["create"],
					"after": {"settings": [{"user_labels": {"owner": "team"}}]},
				},
			},
		],
	}
	count(deny) == 12 with input as plan
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
