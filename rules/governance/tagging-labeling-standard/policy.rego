package policy

import rego.v1

# governance/tagging-labeling-standard.md § Section 5 – Azure Required Tags; Section 6.2 – Resources
# TAG-001: All Nile-managed Azure resources must contain the required Azure tags defined by the standard.
# governance/tagging-labeling-standard.md § Section 7 – GCP Label Standard
# TAG-002: All Nile-managed GCP resources must contain the required GCP labels defined by the standard.
# governance/tagging-labeling-standard.md § Section 9 – Metadata Quality Rules, Rule 1 – No Placeholder Values; Section 10 – Metadata Validation Expectations
# TAG-003: Required metadata values must not be placeholders.
# governance/tagging-labeling-standard.md § Section 9 – Metadata Quality Rules, Rule 3 – Environment Values Must Be Standardized
# TAG-004: Environment metadata should use one of dev, test, stage, prod, or sandbox.

default allow := true

required_azure_tags := [
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
]

required_gcp_labels := [
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
]

placeholder_values := {
	"tbd",
	"test",
	"unknown",
	"placeholder",
	"changeme",
	"none",
}

allowed_environments := {
	"dev",
	"test",
	"stage",
	"prod",
	"sandbox",
}

managed_change(rc) if {
	rc.mode == "managed"
	some action in rc.change.actions
	action in {"create", "update"}
}

azure_resource(rc) if {
	managed_change(rc)
	startswith(rc.type, "azurerm_")
	rc.type != "azurerm_route_table"
}

gcp_resource(rc) if {
	managed_change(rc)
	startswith(rc.type, "google_")
}

# Provider types with no labels attribute (generate skips them; TAG-002 must not fire).
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
	gcp_resource(rc)
	not gcp_label_incapable_types[rc.type]
}

nonempty_string(val) if {
	is_string(val)
	trim(val, " \t\n\r") != ""
}

normalized_string(val) := out if {
	nonempty_string(val)
	out := lower(trim(val, " \t\n\r"))
}

placeholder_string(val) if {
	norm := normalized_string(val)
	placeholder_values[norm]
}

deny contains msg if {
	some rc in input.resource_changes
	azure_resource(rc)
	tags := object.get(rc.change.after, "tags", {})
	some key in required_azure_tags
	not nonempty_string(object.get(tags, key, ""))
	msg := sprintf("TAG-001 governance/tagging-labeling-standard.md § Section 5 – Azure Required Tags; Section 6.2 – Resources: %s missing required Azure tag %q", [resource_ref(rc), key])
}

deny contains msg if {
	some rc in input.resource_changes
	gcp_labelable_resource(rc)
	labels := gcp_labels(rc)
	some key in required_gcp_labels
	not nonempty_string(object.get(labels, key, ""))
	msg := sprintf("TAG-002 governance/tagging-labeling-standard.md § Section 7 – GCP Label Standard: %s missing required GCP label %q", [resource_ref(rc), key])
}

deny contains msg if {
	some rc in input.resource_changes
	azure_resource(rc)
	tags := object.get(rc.change.after, "tags", {})
	some key in required_azure_tags
	val := object.get(tags, key, "")
	nonempty_string(val)
	placeholder_string(val)
	msg := sprintf("TAG-003 governance/tagging-labeling-standard.md § Section 9 – Metadata Quality Rules, Rule 1 – No Placeholder Values: %s uses placeholder Azure tag %q=%q", [resource_ref(rc), key, val])
}

deny contains msg if {
	some rc in input.resource_changes
	gcp_labelable_resource(rc)
	labels := gcp_labels(rc)
	some key in required_gcp_labels
	val := object.get(labels, key, "")
	nonempty_string(val)
	placeholder_string(val)
	msg := sprintf("TAG-003 governance/tagging-labeling-standard.md § Section 9 – Metadata Quality Rules, Rule 1 – No Placeholder Values: %s uses placeholder GCP label %q=%q", [resource_ref(rc), key, val])
}

deny contains msg if {
	some rc in input.resource_changes
	azure_resource(rc)
	tags := object.get(rc.change.after, "tags", {})
	env := object.get(tags, "environment", "")
	nonempty_string(env)
	norm := normalized_string(env)
	not allowed_environments[norm]
	msg := sprintf("TAG-004 governance/tagging-labeling-standard.md § Section 9 – Metadata Quality Rules, Rule 3 – Environment Values Must Be Standardized: %s has non-standard Azure environment %q", [resource_ref(rc), env])
}

deny contains msg if {
	some rc in input.resource_changes
	gcp_labelable_resource(rc)
	labels := gcp_labels(rc)
	env := object.get(labels, "environment", "")
	nonempty_string(env)
	norm := normalized_string(env)
	not allowed_environments[norm]
	msg := sprintf("TAG-004 governance/tagging-labeling-standard.md § Section 9 – Metadata Quality Rules, Rule 3 – Environment Values Must Be Standardized: %s has non-standard GCP environment %q", [resource_ref(rc), env])
}

# Structured agent guidance. This is advisory direction from policy, not an HCL patch.
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
	not nonempty_string(object.get(labels, key, ""))
	guidance := {
		"control_id": "TAG-002",
		"resource_address": resource_ref(rc),
		"operation": "add_or_correct_metadata",
		"target_path": sprintf("%s.%s", [gcp_metadata_path(rc), key]),
		"desired_state": "required non-empty GCP label",
		"value_source": "prefer source AWS tags or approved migration metadata; if unavailable, ask for an owner-approved value and document the assumption",
		"rationale": "The destination resource plan lacks a required Nile label at its provider-schema path.",
	}
}

remediation contains guidance if {
	some rc in input.resource_changes
	gcp_labelable_resource(rc)
	labels := gcp_labels(rc)
	some key in required_gcp_labels
	value := object.get(labels, key, "")
	nonempty_string(value)
	placeholder_string(value)
	guidance := {
		"control_id": "TAG-003",
		"resource_address": resource_ref(rc),
		"operation": "replace_placeholder_metadata",
		"target_path": sprintf("%s.%s", [gcp_metadata_path(rc), key]),
		"desired_state": "meaningful non-placeholder value satisfying the Nile standard",
		"value_source": "source AWS metadata first; otherwise request owner-approved value; never copy a placeholder",
		"rationale": "The current planned value is prohibited as a placeholder.",
	}
}

remediation contains guidance if {
	some rc in input.resource_changes
	gcp_labelable_resource(rc)
	labels := gcp_labels(rc)
	env := object.get(labels, "environment", "")
	nonempty_string(env)
	norm := normalized_string(env)
	not allowed_environments[norm]
	guidance := {
		"control_id": "TAG-004",
		"resource_address": resource_ref(rc),
		"operation": "normalize_environment_metadata",
		"target_path": sprintf("%s.environment", [gcp_metadata_path(rc)]),
		"desired_state": "one of dev, test, stage, prod, sandbox",
		"value_source": "derive from source environment or migration mapping; do not infer production status",
		"rationale": "The planned environment label is outside the organization-approved vocabulary.",
	}
}


remediation contains guidance if {
	some rc in input.resource_changes
	azure_resource(rc)
	tags := object.get(rc.change.after, "tags", {})
	some key in required_azure_tags
	not nonempty_string(object.get(tags, key, ""))
	guidance := {"control_id": "TAG-001", "resource_address": resource_ref(rc), "operation": "add_or_correct_metadata", "target_path": sprintf("tags.%s", [key]), "desired_state": "required non-empty Azure tag", "value_source": "source AWS metadata or owner-approved migration mapping; document assumptions rather than inventing business metadata", "rationale": "The plan lacks a required Azure tag."}
}

remediation contains guidance if {
	some rc in input.resource_changes
	azure_resource(rc)
	tags := object.get(rc.change.after, "tags", {})
	some key in required_azure_tags
	value := object.get(tags, key, "")
	placeholder_string(value)
	guidance := {"control_id": "TAG-003", "resource_address": resource_ref(rc), "operation": "replace_placeholder_metadata", "target_path": sprintf("tags.%s", [key]), "desired_state": "meaningful value; not tbd/test/unknown/placeholder/changeme/none", "value_source": "source AWS metadata or owner approval", "rationale": "The current tag is a prohibited placeholder."}
}

remediation contains guidance if {
	some rc in input.resource_changes
	azure_resource(rc)
	tags := object.get(rc.change.after, "tags", {})
	env := object.get(tags, "environment", "")
	nonempty_string(env)
	norm := normalized_string(env)
	not allowed_environments[norm]
	guidance := {"control_id": "TAG-004", "resource_address": resource_ref(rc), "operation": "normalize_environment_metadata", "target_path": "tags.environment", "desired_state": "one of dev, test, stage, prod, sandbox", "value_source": "source environment or owner-approved mapping; do not infer production status", "rationale": "The environment tag is outside the standard vocabulary."}
}

resource_ref(rc) := ref if {
	address := object.get(rc, "address", "")
	nonempty_string(address)
	ref := sprintf("%s", [address])
} else := ref if {
	ref := sprintf("%s.%s", [rc.type, rc.name])
}
