# Living-governance artifact schemas

Harness-only JSON Schema for this-run evidence. **No Nile Priority-1 control catalog lives here.**

Agents (and `governance_conform.py`) write:

| File under `azure|gcp/artifacts/` | Schema id |
| --- | --- |
| `governance-source.json` | `nile-governance-source/v1` |
| `resource-inventory.json` | `nile-resource-inventory/v1` |
| `governance-decision-tree.json` | `nile-governance-decision-tree/v1` (agent-authored from refreshed docs) |
| `governance-findings.json` | `nile-governance-findings/v1` |
| `governance-conformance-report.json` | `nile-governance-conformance-report/v1` |

`governance-validator.py` is Python authored from the tree, not a schema. `governance-exceptions.md` lists blocking residuals only. OPA output `governance-opa-guidance.json` is generated from Rego `data.policy.remediation`; the Python checker transports it and never edits HCL.

Runtime docs are fetched into `$WORK_ROOT/governance/` each conform visit. The optional Nile-Factory submodule `docs/nile-governance` is a human pin, not the runner source.
