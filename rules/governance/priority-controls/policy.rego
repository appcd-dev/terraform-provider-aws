package policy

import rego.v1

# governance/priority-controls.md § Section 5 – Priority 1 Controls; Section 9 – Priority by Cloud
# PRIO-001: Production-priority metadata controls require Nile-managed resources to carry the required Azure tags or GCP labels defined in the Tagging and Labeling Standard.

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

gcp_labels(rc) := labels if {
	rc.type == "google_sql_database_instance"
	settings := object.get(rc.change.after, "settings", [])
	is_array(settings)
	count(settings) > 0
	labels := object.get(settings[0], "user_labels", {})
} else := object.get(rc.change.after, "labels", {})

managed_change(rc) if {
	rc.mode == "managed"
	some action in rc.change.actions
	action in {"create", "update"}
}

gcp_labelable_resource(rc) if {
	managed_change(rc)
	startswith(rc.type, "google_")
	not gcp_label_incapable_types[rc.type]
}

nonempty(s) if {
	is_string(s)
	trim(s, " \t\n\r") != ""
}

deny contains msg if {
	some rc in input.resource_changes
	managed_change(rc)
	startswith(rc.type, "azurerm_")
	tags := object.get(rc.change.after, "tags", {})
	some required in required_azure_tags
	not nonempty(object.get(tags, required, ""))
	msg := sprintf("PRIO-001: governance/priority-controls.md § Section 5 – Priority 1 Controls; Section 9 – Priority by Cloud: %s missing required Azure tag %q", [rc.address, required])
}

deny contains msg if {
	some rc in input.resource_changes
	gcp_labelable_resource(rc)
	labels := gcp_labels(rc)
	some required in required_gcp_labels
	not nonempty(object.get(labels, required, ""))
	msg := sprintf("PRIO-001: governance/priority-controls.md § Section 5 – Priority 1 Controls; Section 9 – Priority by Cloud: %s missing required GCP label %q", [rc.address, required])
}
