package policy

import rego.v1

# governance/control-matrix.md § Section 4 – Control Matrix – Metadata
# governance/control-matrix.md § Section 9 – StackGen Validation Guidance – Metadata
# CM-001: Ownership, cost, repo, service, and APM metadata must be present and validated on governed resources.

default allow := true

required_metadata_keys := {"owner", "cost-center", "repo", "service", "apmid"}

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
}

nonempty(s) if {
	is_string(s)
	trim(s, " \t\n\r") != ""
}

has_supported_metadata_map(after) if {
	is_object(object.get(after, "tags", null))
}

has_supported_metadata_map(after) if {
	is_object(object.get(after, "labels", null))
}

# Azure tags use hyphens (apmid, cost-center); GCP labels use underscores (apm_id, cost_center).
# "apmid" ↔ "apm_id" needs an explicit remap (no hyphen to rewrite).
extra_metadata_aliases := {
	"apmid": {"apm_id"},
	"apm_id": {"apmid"},
}

metadata_key_aliases(key) := {key, replace(key, "-", "_"), replace(key, "_", "-")} | object.get(extra_metadata_aliases, key, set())

map_has_metadata(m, key) if {
	is_object(m)
	some alias in metadata_key_aliases(key)
	nonempty(object.get(m, alias, ""))
}

has_metadata(after, key) if {
	map_has_metadata(object.get(after, "tags", null), key)
}

has_metadata(after, key) if {
	map_has_metadata(object.get(after, "labels", null), key)
}

deny contains msg if {
	some rc in input.resource_changes
	rc.change.actions[_] in {"create", "update"}
	not gcp_label_incapable_types[rc.type]
	after := object.get(rc.change, "after", {})
	has_supported_metadata_map(after)
	some required in required_metadata_keys
	not has_metadata(after, required)
	msg := sprintf("CM-001 governance/control-matrix.md Section 4/9: %s missing required metadata %q on %s", [rc.address, required, rc.type])
}
