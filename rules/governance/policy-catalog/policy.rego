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
required_gcp_labels := {"owner", "created-by", "cost-center", "environment", "function", "service", "repo", "applicationname", "name", "notificationdistlist", "ssp", "trproductid", "apmid"}
approved_gcp_regions := {"us-central1", "us-east1", "us-east4", "us-west1", "us-west2", "us-west3", "us-west4"}

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
  after := object.get(rc.change, "after", {})
  labels := object.get(after, "labels", null)
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
