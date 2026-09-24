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
	startswith(rc.type, "google_")
	relevant_action(rc)
	labels := object.get(rc.change.after, "labels", {})
	some required in required_gcp_labels
	not nonempty_string(object.get(labels, required, ""))
	msg := sprintf("PRG-002 governance/production-readiness-gates.md ## 9. Gate 4 — Metadata: %s missing required GCP label %q", [rc.address, required])
}

deny contains msg if {
	some rc in input.resource_changes
	startswith(rc.type, "google_")
	relevant_action(rc)
	labels := object.get(rc.change.after, "labels", {})
	some required in required_gcp_labels
	value := object.get(labels, required, "")
	nonempty_string(value)
	placeholder_string(value)
	msg := sprintf("PRG-002 governance/production-readiness-gates.md ## 9. Gate 4 — Metadata: %s GCP label %q uses placeholder value %q", [rc.address, required, value])
}
