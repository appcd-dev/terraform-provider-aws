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

managed_change(rc) if {
	rc.mode == "managed"
	some action in rc.change.actions
	action in {"create", "update"}
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
	managed_change(rc)
	startswith(rc.type, "google_")
	labels := object.get(rc.change.after, "labels", {})
	some required in required_gcp_labels
	not nonempty(object.get(labels, required, ""))
	msg := sprintf("PRIO-001: governance/priority-controls.md § Section 5 – Priority 1 Controls; Section 9 – Priority by Cloud: %s missing required GCP label %q", [rc.address, required])
}
