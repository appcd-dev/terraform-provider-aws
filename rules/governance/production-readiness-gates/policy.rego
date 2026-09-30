package policy

import rego.v1

# governance/production-readiness-gates.md § ## 9. Gate 4 — Metadata / Azure Considerations / Common Failure Conditions
# PRG-001: Nile-managed Azure resources must include the required metadata tags and must not use placeholder values.
# governance/production-readiness-gates.md § ## 9. Gate 4 — Metadata / GCP Considerations / Common Failure Conditions
# PRG-002: Nile-managed GCP resources must include the required metadata labels and must not use placeholder values.

default allow := true

required_azure_tags := {
	"owner",
	"created-by",
	"cost-center",
	"environment",
	"function",
	"service",
	"repo",
	"applicationname",
	"name",
	"notificationdistlist",
	"ssp",
	"trproductid",
	"apmid",
}

required_gcp_labels := {
	"owner",
	"created_by",
	"cost_center",
	"environment",
	"function",
	"service",
	"repo",
	"application_name",
	"name",
	"notification_distlist",
	"ssp",
	"tr_product_id",
	"apm_id",
}

placeholder_values := {
	"tbd",
	"test",
	"unknown",
	"changeme",
}

# Provider types with no labels attribute (same set as tagging-labeling-standard TAG-002).
gcp_label_incapable_types := {
	"google_compute_network",
	"google_compute_subnetwork",
	"google_compute_firewall",
	"google_compute_route",
	"google_compute_router",
	"google_compute_router_nat",
	"google_compute_global_address",
	"google_compute_address",
	"google_compute_forwarding_rule",
	"google_compute_global_forwarding_rule",
	"google_compute_target_http_proxy",
	"google_compute_target_https_proxy",
	"google_compute_url_map",
	"google_compute_backend_service",
	"google_compute_health_check",
	"google_compute_firewall_policy",
	"google_compute_firewall_policy_rule",
	"google_service_account",
	"google_service_account_iam_member",
	"google_service_account_iam_binding",
	"google_project_iam_member",
	"google_project_iam_binding",
	"google_project_iam_custom_role",
	"google_project_service",
	# These resources expose no supported labels field.
	"google_logging_project_bucket_config",
	"google_bigtable_table",
}

# Metadata lives at provider-schema-specific paths for some GCP resources.
# GKE cluster labels are `resource_labels`; node-pool labels are
# `node_config[].labels`; Cloud SQL labels are `settings[].user_labels`.
gcp_labels(rc) := labels if {
	rc.type == "google_sql_database_instance"
	settings := object.get(rc.change.after, "settings", [])
	is_array(settings)
	count(settings) > 0
	labels := object.get(settings[0], "user_labels", {})
} else := object.get(rc.change.after, "resource_labels", {}) if {
	rc.type == "google_container_cluster"
} else := labels if {
	rc.type == "google_container_node_pool"
	node_config := object.get(rc.change.after, "node_config", [])
	is_array(node_config)
	count(node_config) > 0
	labels := object.get(node_config[0], "labels", {})
} else := object.get(rc.change.after, "labels", {})

gcp_labelable_resource(rc) if {
	startswith(rc.type, "google_")
	relevant_action(rc)
	not gcp_label_incapable_types[rc.type]
}

relevant_action(rc) if {
	rc.change.actions[_] == "create"
}

relevant_action(rc) if {
	rc.change.actions[_] == "update"
}

nonempty_string(s) if {
	is_string(s)
	trim(s, " \t\n\r") != ""
}

normalized_string(s) := lower(trim(s, " \t\n\r")) if {
	is_string(s)
}

placeholder_string(s) if {
	normalized_string(s) in placeholder_values
}

deny contains msg if {
	some rc in input.resource_changes
	startswith(rc.type, "azurerm_")
	relevant_action(rc)
	tags := object.get(rc.change.after, "tags", {})
	some required in required_azure_tags
	not nonempty_string(object.get(tags, required, ""))
	msg := sprintf("PRG-001 governance/production-readiness-gates.md ## 9. Gate 4 — Metadata: %s missing required Azure tag %q", [rc.address, required])
}

deny contains msg if {
	some rc in input.resource_changes
	startswith(rc.type, "azurerm_")
	relevant_action(rc)
	tags := object.get(rc.change.after, "tags", {})
	some required in required_azure_tags
	value := object.get(tags, required, "")
	nonempty_string(value)
	placeholder_string(value)
	msg := sprintf("PRG-001 governance/production-readiness-gates.md ## 9. Gate 4 — Metadata: %s Azure tag %q uses placeholder value %q", [rc.address, required, value])
}

deny contains msg if {
	some rc in input.resource_changes
	gcp_labelable_resource(rc)
	labels := gcp_labels(rc)
	some required in required_gcp_labels
	not nonempty_string(object.get(labels, required, ""))
	msg := sprintf("PRG-002 governance/production-readiness-gates.md ## 9. Gate 4 — Metadata: %s missing required GCP label %q", [rc.address, required])
}

deny contains msg if {
	some rc in input.resource_changes
	gcp_labelable_resource(rc)
	labels := gcp_labels(rc)
	some required in required_gcp_labels
	value := object.get(labels, required, "")
	nonempty_string(value)
	placeholder_string(value)
	msg := sprintf("PRG-002 governance/production-readiness-gates.md ## 9. Gate 4 — Metadata: %s GCP label %q uses placeholder value %q", [rc.address, required, value])
}

# Structured agent guidance. This is advisory direction from policy, not an HCL patch.

remediation contains guidance if {
	some rc in input.resource_changes
	startswith(rc.type, "azurerm_")
	relevant_action(rc)
	tags := object.get(rc.change.after, "tags", {})
	some key in required_azure_tags
	not nonempty_string(object.get(tags, key, ""))
	guidance := {"control_id": "PRG-001", "resource_address": rc.address, "operation": "add_or_correct_metadata", "target_path": sprintf("tags.%s", [key]), "desired_state": "meaningful required Azure tag", "value_source": "source AWS metadata or owner approval; record migration assumptions", "rationale": "Production-readiness metadata is missing from the plan."}
}

gcp_metadata_path(rc) := "resource_labels" if rc.type == "google_container_cluster"
gcp_metadata_path(rc) := "node_config[].labels" if rc.type == "google_container_node_pool"
gcp_metadata_path(rc) := "settings[].user_labels" if rc.type == "google_sql_database_instance"
gcp_metadata_path(rc) := "labels" if {
	rc.type != "google_container_cluster"
	rc.type != "google_container_node_pool"
	rc.type != "google_sql_database_instance"
	startswith(rc.type, "google_")
}

remediation contains guidance if {
	some rc in input.resource_changes
	gcp_labelable_resource(rc)
	labels := gcp_labels(rc)
	some key in required_gcp_labels
	value := object.get(labels, key, "")
	placeholder_string(value)
	guidance := {"control_id": "PRG-002", "resource_address": rc.address, "operation": "replace_placeholder_metadata", "target_path": sprintf("%s.%s", [gcp_metadata_path(rc), key]), "desired_state": "meaningful non-placeholder GCP label", "value_source": "source AWS metadata or owner approval; document assumptions", "rationale": "Production-readiness metadata must be meaningful, not a placeholder."}
}
