package policy

import rego.v1

# governance/control-matrix.md § Section 4 – Control Matrix – Metadata
# governance/control-matrix.md § Section 9 – StackGen Validation Guidance – Metadata
# CM-001: Ownership, cost, repo, service, and APM metadata must be present and validated on governed resources.

default allow := true

required_metadata_keys := {"owner", "cost-center", "repo", "service", "apmid"}

nonempty(s) if {
    is_string(s)
    trim(s, " 	
") != ""
}

has_supported_metadata_map(after) if {
    is_object(object.get(after, "tags", null))
}

has_supported_metadata_map(after) if {
    is_object(object.get(after, "labels", null))
}

metadata_value(after, key) := value if {
    tags := object.get(after, "tags", null)
    is_object(tags)
    value := object.get(tags, key, "")
}

metadata_value(after, key) := value if {
    labels := object.get(after, "labels", null)
    is_object(labels)
    value := object.get(labels, key, "")
}

deny contains msg if {
    some rc in input.resource_changes
    rc.change.actions[_] in {"create", "update"}
    after := object.get(rc.change, "after", {})
    has_supported_metadata_map(after)
    some required in required_metadata_keys
    not nonempty(metadata_value(after, required))
    msg := sprintf("CM-001 governance/control-matrix.md Section 4/9: %s missing required metadata %q on %s", [rc.address, required, rc.type])
}
