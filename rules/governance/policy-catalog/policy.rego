package policy

import rego.v1

# governance/policy-catalog.md § Section 6.10 – Tagging
# NPC-001: Azure resources subject to the tagging policy must include all required Azure tags.
# governance/policy-catalog.md § Section 8 – Cross-Cloud Governance Intent; Section 11 – StackGen Validation Guidance
# NPC-002: GCP resources must include required labels mapped from the Nile tagging and labeling standard.
# governance/policy-catalog.md § Section 6.7 – Network Security
# NPC-003: Azure network interfaces must not expose public IP addresses.
# governance/policy-catalog.md § Section 7.3 – Network Security Controls
# NPC-004: GCP compute instances must not configure external IP access.
# governance/policy-catalog.md § Section 6.3 – Data Protection
# NPC-005: Azure App Service and Function App resources must enforce HTTPS-only access.
# governance/policy-catalog.md § Section 6.3 – Data Protection
# NPC-006: Azure storage accounts must require secure transfer.
# governance/policy-catalog.md § Section 6.3 – Data Protection
# NPC-007: Azure Key Vault resources must enable soft delete and deletion protection.
# governance/policy-catalog.md § Section 6.4 – Identity Management
# NPC-008: Azure App Service and Function App resources must use managed identity.
# governance/policy-catalog.md § Section 7.5 – Compliance and Governance Controls
# NPC-009: GCP resources with regional or zonal locations must use approved regions.

default allow := true

required_azure_tags := {"owner", "created-by", "cost-center", "environment", "function", "service", "repo", "applicationname", "name", "notificationdistlist", "ssp", "trproductid", "apmid"}

# Underscores match GCP label grammar (same as TAG-002 / PRG-002).
required_gcp_labels := {"owner", "created_by", "cost_center", "environment", "function", "service", "repo", "application_name", "name", "notification_distlist", "ssp", "tr_product_id", "apm_id"}
approved_gcp_regions := {"us-central1", "us-east1", "us-east4", "us-west1", "us-west2", "us-west3", "us-west4"}

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

azure_https_types := {
	"azurerm_app_service",
	"azurerm_linux_web_app",
	"azurerm_windows_web_app",
	"azurerm_function_app",
	"azurerm_linux_function_app",
	"azurerm_windows_function_app",
}

azure_identity_types := azure_https_types

is_managed_change(rc) if {
	rc.mode == "managed"
	some action in rc.change.actions
	action in {"create", "update"}
}

nonempty_string(s) if {
	is_string(s)
	trim(s, " \t\n\r") != ""
}

has_identity(after) if {
	identity := object.get(after, "identity", null)
	identity != null
	not is_array(identity)
	nonempty_string(object.get(identity, "type", ""))
}

has_identity(after) if {
	identities := object.get(after, "identity", [])
	is_array(identities)
	some identity in identities
	nonempty_string(object.get(identity, "type", ""))
}

location_value(after) := value if {
	value := object.get(after, "location", "")
	nonempty_string(value)
}

location_value(after) := value if {
	value := object.get(after, "region", "")
	nonempty_string(value)
}

location_value(after) := region if {
	zone := object.get(after, "zone", "")
	nonempty_string(zone)
	parts := split(zone, "-")
	count(parts) >= 3
	prefix := array.slice(parts, 0, count(parts) - 1)
	region := concat("-", prefix)
}

deny contains msg if {
	some rc in input.resource_changes
	is_managed_change(rc)
	startswith(rc.type, "azurerm_")
	not startswith(rc.type, "azurerm_route_table")
	after := object.get(rc.change, "after", {})
	tags := object.get(after, "tags", {})
	some required in required_azure_tags
	not nonempty_string(object.get(tags, required, ""))
	msg := sprintf("NPC-001 governance/policy-catalog.md Section 6.10: %s missing required Azure tag %q on %s", [rc.address, required, rc.type])
}

deny contains msg if {
	some rc in input.resource_changes
	is_managed_change(rc)
	startswith(rc.type, "google_")
	not gcp_label_incapable_types[rc.type]
	after := object.get(rc.change, "after", {})
	labels := gcp_labels(rc)
	labels != null
	some required in required_gcp_labels
	not nonempty_string(object.get(labels, required, ""))
	msg := sprintf("NPC-002 governance/policy-catalog.md Sections 8 and 11: %s missing required GCP label %q on %s", [rc.address, required, rc.type])
}

deny contains msg if {
	some rc in input.resource_changes
	is_managed_change(rc)
	rc.type == "azurerm_network_interface"
	after := object.get(rc.change, "after", {})
	some ipconf in object.get(after, "ip_configuration", [])
	nonempty_string(object.get(ipconf, "public_ip_address_id", ""))
	msg := sprintf("NPC-003 governance/policy-catalog.md Section 6.7: %s configures a public IP on an Azure network interface", [rc.address])
}

deny contains msg if {
	some rc in input.resource_changes
	is_managed_change(rc)
	rc.type == "google_compute_instance"
	after := object.get(rc.change, "after", {})
	some nic in object.get(after, "network_interface", [])
	count(object.get(nic, "access_config", [])) > 0
	msg := sprintf("NPC-004 governance/policy-catalog.md Section 7.3: %s configures external IP access on a GCP compute instance", [rc.address])
}

deny contains msg if {
	some rc in input.resource_changes
	is_managed_change(rc)
	rc.type in azure_https_types
	after := object.get(rc.change, "after", {})
	object.get(after, "https_only", false) != true
	msg := sprintf("NPC-005 governance/policy-catalog.md Section 6.3: %s must set https_only=true", [rc.address])
}

deny contains msg if {
	some rc in input.resource_changes
	is_managed_change(rc)
	rc.type == "azurerm_storage_account"
	after := object.get(rc.change, "after", {})
	secure_transfer := object.get(after, "https_traffic_only_enabled", object.get(after, "enable_https_traffic_only", false))
	secure_transfer != true
	msg := sprintf("NPC-006 governance/policy-catalog.md Section 6.3: %s must require secure transfer for Azure Storage", [rc.address])
}

deny contains msg if {
	some rc in input.resource_changes
	is_managed_change(rc)
	rc.type == "azurerm_key_vault"
	after := object.get(rc.change, "after", {})
	object.get(after, "soft_delete_retention_days", 0) <= 0
	msg := sprintf("NPC-007 governance/policy-catalog.md Section 6.3: %s must enable Key Vault soft delete retention", [rc.address])
}

deny contains msg if {
	some rc in input.resource_changes
	is_managed_change(rc)
	rc.type == "azurerm_key_vault"
	after := object.get(rc.change, "after", {})
	object.get(after, "purge_protection_enabled", false) != true
	msg := sprintf("NPC-007 governance/policy-catalog.md Section 6.3: %s must enable Key Vault purge protection", [rc.address])
}

deny contains msg if {
	some rc in input.resource_changes
	is_managed_change(rc)
	rc.type in azure_identity_types
	after := object.get(rc.change, "after", {})
	not has_identity(after)
	msg := sprintf("NPC-008 governance/policy-catalog.md Section 6.4: %s must configure managed identity", [rc.address])
}

deny contains msg if {
	some rc in input.resource_changes
	is_managed_change(rc)
	startswith(rc.type, "google_")
	after := object.get(rc.change, "after", {})
	region := location_value(after)
	not approved_gcp_regions[region]
	msg := sprintf("NPC-009 governance/policy-catalog.md Section 7.5: %s uses unapproved GCP region/zone %q", [rc.address, region])
}


gcp_labelable_change(rc) if {
	is_managed_change(rc)
	startswith(rc.type, "google_")
	not gcp_label_incapable_types[rc.type]
}

remediation contains guidance if {
	some rc in input.resource_changes
	is_managed_change(rc)
	rc.type == "google_compute_instance"
	after := object.get(rc.change, "after", {})
	some nic in object.get(after, "network_interface", [])
	count(object.get(nic, "access_config", [])) > 0
	guidance := {
		"control_id": "NPC-004",
		"resource_address": rc.address,
		"operation": "remove_or_replace_public_access",
		"target_path": "network_interface[].access_config",
		"desired_state": "no external IP unless an approved exception explicitly requires it",
		"value_source": "review source AWS exposure, callers, ingress paths, and approved network architecture; preserve required connectivity through private routing/load balancing",
		"rationale": "The resource plan configures external IP access; the policy requires private-by-default compute.",
	}
}

remediation contains guidance if {
	some rc in input.resource_changes
	is_managed_change(rc)
	startswith(rc.type, "google_")
	after := object.get(rc.change, "after", {})
	region := location_value(after)
	not approved_gcp_regions[region]
	guidance := {
		"control_id": "NPC-009",
		"resource_address": rc.address,
		"operation": "select_approved_region",
		"target_path": "location | region | zone",
		"desired_state": "use a region in approved_gcp_regions; if zonal, choose a zone within that region",
		"value_source": "source resource location, data residency requirements, service availability, and owner-approved region; do not default blindly",
		"rationale": "The planned location is not in the organization-approved GCP region set.",
	}
}

remediation contains guidance if {
	some rc in input.resource_changes
	gcp_labelable_change(rc)
	labels := gcp_labels(rc)
	some key in required_gcp_labels
	not nonempty_string(object.get(labels, key, ""))
	guidance := {
		"control_id": "NPC-002",
		"resource_address": rc.address,
		"operation": "add_or_correct_metadata",
		"target_path": sprintf("%s.%s", [gcp_metadata_path(rc), key]),
		"desired_state": "required non-empty GCP label",
		"value_source": "prefer source AWS tags or approved migration metadata; if unavailable, ask for an owner-approved value and document the assumption",
		"rationale": "The destination resource plan lacks a required Nile label at its provider-schema path.",
	}
}


remediation contains guidance if {
	some rc in input.resource_changes
	is_managed_change(rc)
	startswith(rc.type, "google_")
	after := object.get(rc.change, "after", {})
	region := location_value(after)
	not approved_gcp_regions[region]
	guidance := {
		"control_id": "NPC-009",
		"resource_address": rc.address,
		"operation": "select_approved_region",
		"target_path": "location | region | zone",
		"desired_state": "use an approved region; for zonal resources choose a zone within an approved region",
		"value_source": "source AWS location plus data residency, service availability, and owner approval; do not default blindly",
		"rationale": "The planned location is not in the approved GCP region set.",
	}
}

remediation contains guidance if {
	some rc in input.resource_changes
	is_managed_change(rc)
	rc.type == "google_compute_instance"
	after := object.get(rc.change, "after", {})
	some nic in object.get(after, "network_interface", [])
	count(object.get(nic, "access_config", [])) > 0
	guidance := {
		"control_id": "NPC-004",
		"resource_address": rc.address,
		"operation": "remove_or_replace_external_ip",
		"target_path": "network_interface[].access_config",
		"desired_state": "no external IP unless explicitly approved; preserve required access through approved private ingress/egress design",
		"value_source": "source AWS exposure, application callers, ingress needs, and approved network architecture",
		"rationale": "The planned instance configures external IP access contrary to private-by-default policy.",
	}
}

remediation contains guidance if {
	some rc in input.resource_changes
	is_managed_change(rc)
	startswith(rc.type, "azurerm_")
	tags := object.get(rc.change.after, "tags", {})
	some key in required_azure_tags
	not nonempty_string(object.get(tags, key, ""))
	guidance := {"control_id": "NPC-001", "resource_address": rc.address, "operation": "add_or_correct_metadata", "target_path": sprintf("tags.%s", [key]), "desired_state": "required non-empty Azure tag", "value_source": "source AWS tags or approved migration metadata; ask an owner and document assumptions if unknown", "rationale": "The planned resource lacks a required Nile ownership/operations tag."}
}


# Remaining direct GCP/Azure controls: direction is intentionally a constraint,
# not an auto-selected value or Terraform patch.
remediation contains guidance if {
	some rc in input.resource_changes
	is_managed_change(rc)
	rc.type == "azurerm_network_interface"
	after := object.get(rc.change, "after", {})
	some ipconf in object.get(after, "ip_configuration", [])
	nonempty_string(object.get(ipconf, "public_ip_address_id", ""))
	guidance := {"control_id": "NPC-003", "resource_address": rc.address, "operation": "remove_or_replace_public_ip", "target_path": "ip_configuration[].public_ip_address_id", "desired_state": "no public IP unless approved; retain required connectivity through the approved network design", "value_source": "source routing, ingress requirements, and owner-approved architecture", "rationale": "The NIC plan attaches a public IP contrary to the policy."}
}

remediation contains guidance if {
	some rc in input.resource_changes
	is_managed_change(rc)
	rc.type in azure_https_types
	after := object.get(rc.change, "after", {})
	object.get(after, "https_only", false) != true
	guidance := {"control_id": "NPC-005", "resource_address": rc.address, "operation": "enable_https_only", "target_path": "https_only", "desired_state": "true", "value_source": "policy-required security setting; verify application clients use HTTPS", "rationale": "The service plan does not enforce HTTPS-only access."}
}

remediation contains guidance if {
	some rc in input.resource_changes
	is_managed_change(rc)
	rc.type == "azurerm_storage_account"
	after := object.get(rc.change, "after", {})
	object.get(after, "https_traffic_only_enabled", object.get(after, "enable_https_traffic_only", false)) != true
	guidance := {"control_id": "NPC-006", "resource_address": rc.address, "operation": "require_secure_transfer", "target_path": "https_traffic_only_enabled", "desired_state": "true", "value_source": "policy-required transport security setting; confirm all clients support TLS", "rationale": "The storage plan does not require secure transfer."}
}

remediation contains guidance if {
	some rc in input.resource_changes
	is_managed_change(rc)
	rc.type == "azurerm_key_vault"
	after := object.get(rc.change, "after", {})
	object.get(after, "soft_delete_retention_days", 0) <= 0
	guidance := {"control_id": "NPC-007", "resource_address": rc.address, "operation": "configure_soft_delete_retention", "target_path": "soft_delete_retention_days", "desired_state": "positive retention period complying with current provider/policy bounds", "value_source": "organization retention standard; do not invent the retention period", "rationale": "The key vault plan lacks required soft-delete retention."}
}

remediation contains guidance if {
	some rc in input.resource_changes
	is_managed_change(rc)
	rc.type == "azurerm_key_vault"
	after := object.get(rc.change, "after", {})
	object.get(after, "purge_protection_enabled", false) != true
	guidance := {"control_id": "NPC-007", "resource_address": rc.address, "operation": "enable_purge_protection", "target_path": "purge_protection_enabled", "desired_state": "true", "value_source": "policy-required destructive-operation protection; check retention and recovery requirements", "rationale": "The key vault plan lacks purge protection."}
}

remediation contains guidance if {
	some rc in input.resource_changes
	is_managed_change(rc)
	rc.type in azure_identity_types
	after := object.get(rc.change, "after", {})
	not has_identity(after)
	guidance := {"control_id": "NPC-008", "resource_address": rc.address, "operation": "configure_managed_identity", "target_path": "identity", "desired_state": "approved system- or user-assigned managed identity", "value_source": "application identity and access design; do not grant roles without a permission review", "rationale": "The service plan lacks managed identity."}
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
