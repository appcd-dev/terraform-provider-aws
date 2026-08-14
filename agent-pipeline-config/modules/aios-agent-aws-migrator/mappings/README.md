# AWS → Azure migration mapping catalog

`aws-to-azure.json` is the single source of truth the migration agent uses to turn an
AWS Terraform resource type into a deterministic Azure migration decision. The blueprint
and generate stages load it on the runner; the demo migration-profile SOP points the
architect agent at it so it does not invent mappings.

## Provenance

Seeded from `appcd-dev/iac-gen` `internal/testdata/templates/migration_mappings/aws-to-azure.json`
(git `b48cbd00`, removed with the migration runtime in `CLOUD-1212`). The original schema
(`resource_migration_map` + `migration_classes` with `attribute_mapping`) is preserved so the
catalog stays compatible with any future iac-gen-style importer. Demo-specific defaults were
normalized and additional high-frequency AWS types were added.

## Schema

```jsonc
{
  "version": "<date>.agent.v<n>",
  "source_cloud": "aws",
  "destination_cloud": "azure",
  "resource_migration_map": {
    "<aws_type>": {
      "default_target_resource_type": "<azurerm_type>",   // iac-gen key; primary Azure target
      "migration_resource_class": "<class>",               // iac-gen key; links into migration_classes
      "category": "<scaffold_category>",                   // agent field; drives generate scaffolding
      "azure_service_label": "<human label>",              // agent field; shown in review docs
      "confidence": 0.0-1.0,                                 // agent field
      "companion_resource_types": ["<azurerm_type>"],      // agent field; extra resources to consider
      "review": "<plain-English review note>"               // agent field
    }
  },
  "migration_classes": {
    "<class>": {
      "target_resource_types": ["<azurerm_type>", "..."],  // primary + alternates
      "attribute_mapping": {                                 // iac-gen key; source attr -> target attr
        "<aws_type>": { "<aws_attr>": { "<azurerm_type>": "<azure_attr>" } }
      }
    }
  }
}
```

### Status semantics

The runner resolver (`scripts/azure_mapping_catalog.py`) returns:

- `mapped` — a concrete Azure target exists (`migration_resource_class` is set and not `non_applicable`).
- `non_applicable` — the AWS type folds into another resource's attributes or has no Azure resource
  (e.g. `aws_s3_bucket_versioning`, `aws_iam_user`). Surfaced in `review-needed.md`; never scaffolded as fake services.
- `unsupported` — the type is not in the catalog. Generate emits a resource group plus a review note only.

### Source-cloud discovery hygiene

Acquisition migrations need **application IAM** (workload roles + custom policies) but
not workforce identity noise:

1. **cloud2code** `default_cloud2code_exclude` skips users/groups/access keys/SAML/OIDC/
   account alias/password policy/server certs/SSH keys — **not** `aws_iam_role`,
   `aws_iam_policy`, `aws_iam_role_policy`, attachments, or instance profiles.
2. **Walle IAM role** Deny covers those human-identity APIs (+ Athena + key pairs) while
   still allowing `ListRoles` / `GetPolicy` / inline policy reads for app permission capture.
3. **Generate** (`app_iam.py`) keeps only workload-trust roles (EC2/Lambda/ECS/EKS/…),
   drops `AWSServiceRoleFor*`, and emits:
   - **GCP**: SA + custom role + binding (AWS actions as comments)
   - **Azure**: UAI + custom role definition + assignment (AWS actions as comments)

Operators who need workforce IAM in a discovery PR must pass an explicit
`cloud2code_include` and a role without the human-IAM Deny.

When you add a new standalone never-map / horizontal type, update both the exclude
list and the Deny policy.

### Emission semantics (operator honesty)

`status=mapped` does **not** mean full equivalent HCL was generated. Each decision also carries `emission`:

| Emission | Meaning |
| --- | --- |
| `full_scaffold` | CAF/WAF-aligned azurerm resources for the category |
| `managed_identity_rbac_scaffold` | Per-workload UAI + custom role definition/assignment; AWS actions in comments for specialist RBAC translation |
| `managed_identity_scaffold` | User-assigned identity only; RBAC stays operator-owned |
| `profile_scaffold` | Thin profile (e.g. Front Door / APIM) requiring deep follow-up |
| `partial_scaffold` | Incomplete category scaffold |
| `resource_group_only` | Placeholder RG + review notes |
| `none` | Nothing generated for this type |

### Scaffold categories

`category` maps onto scaffolds in `azure_iac_generate.py`: `network`, `kubernetes`, `vm`, `vmss`,
`function`, `storage`, `database_postgres`, `database_nosql`, `queue`, `event`, `dns`, `cache`,
`observability`, `containers`, `cdn`, `load_balancer`, `identity`, `static_ip`, `api`, `key_management`,
`analytics`, `data_reference`, `non_applicable`.

Group-level confidence averages only decisions that are not `non_applicable` / `emission=none`
(see `group_confidence` in `azure_mapping_catalog.py`).

## Extending

1. Add the AWS type under `resource_migration_map` with at least `migration_resource_class`,
   `category`, `confidence`, and `review`. Add `default_target_resource_type` for mapped types.
2. Reuse an existing `migration_class` or add a new one under `migration_classes` with
   `target_resource_types` (primary first) and optional `attribute_mapping`.
3. Bump `version`.
4. Bump `local.script_pack_version` in [`../main.tf`](../main.tf) so the runner re-copies the pack,
   and re-preload the script pack on the runner (the sha256 gate fails loudly on drift).
5. Run the offline check: `python3 ../scripts/test_azure_mapping_catalog.py`.

## Non-goals

- Reviving iac-gen's migration manager/API or AppStack topology migration.
- Perfect attribute translation for every AWS field — the catalog provides name/tag-level maps
  plus review notes; generate stays review-candidate (not full AVM landing zones).
