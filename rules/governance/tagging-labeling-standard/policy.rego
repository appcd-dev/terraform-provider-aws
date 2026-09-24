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
	gcp_resource(rc)
	labels := object.get(rc.change.after, "labels", {})
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
	gcp_resource(rc)
	labels := object.get(rc.change.after, "labels", {})
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
	gcp_resource(rc)
	labels := object.get(rc.change.after, "labels", {})
	env := object.get(labels, "environment", "")
	nonempty_string(env)
	norm := normalized_string(env)
	not allowed_environments[norm]
	msg := sprintf("TAG-004 governance/tagging-labeling-standard.md § Section 9 – Metadata Quality Rules, Rule 3 – Environment Values Must Be Standardized: %s has non-standard GCP environment %q", [resource_ref(rc), env])
}

resource_ref(rc) := ref if {
	address := object.get(rc, "address", "")
	nonempty_string(address)
	ref := sprintf("%s", [address])
} else := ref if {
	ref := sprintf("%s.%s", [rc.type, rc.name])
}
