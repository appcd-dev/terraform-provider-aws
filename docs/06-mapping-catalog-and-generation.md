# 6. Mapping catalog and generation

## Dual destination catalogs

| Destination | Catalog | Python |
| --- | --- | --- |
| Azure | `mappings/aws-to-azure.json` | `azure_mapping_catalog.py`, `azure_iac_generate.py` |
| GCP | `mappings/aws-to-gcp.json` | `gcp_mapping_catalog.py`, `gcp_iac_generate.py` |

Both reuse the same **emission** vocabulary (`full_scaffold`, `managed_identity_rbac_scaffold`, `managed_identity_scaffold`, `profile_scaffold`, `resource_group_only`, `none`).

## Pipeline inside generate (Azure shown; GCP is parallel)

```text
aws/groups/*  +  aws-to-azure.json   (or aws-to-gcp.json)
        │
        ▼
  build migration-blueprint.json   (per-group decisions)
        │
        ▼
  azure_iac_generate.py / gcp_iac_generate.py
        │
        ▼
  azure|gcp/groups/<id>/*.tf
  azure|gcp/artifacts/...
```

## Group confidence scoring

Blueprint **group** `confidence` is the average of decisions that still count toward generation quality:

- **Included:** decisions that are not `non_applicable` and have `emission != none`
- **Excluded:** `non_applicable` / `emission=none` (folded S3 companions, Entra-only IAM users, OIDC, Glue catalog, …)

If every decision is non-applicable, group `confidence` is `null` with `confidence_reason=non_applicable_only` (still listed in review-needed). Per-decision confidence stays honest and unchanged.

## Catalog entry fields

Each AWS Terraform resource type row roughly answers:

1. **Can we map it?** (`status`: mapped / non_applicable / …)  
2. **To what destination idea?** (`azure_type` / `gcp_type` / class)  
3. **What HCL do we actually emit?** (`emission`)  
4. **Any attribute hints?** (`attribute_mapping` — often empty for identity-only)

See `mappings/README.md` and `mappings/README-gcp.md` for schema notes and version bumps.

## Emission vs mapped (do not mix them up)

| Catalog says | Generator may emit | Misread to avoid |
| --- | --- | --- |
| `mapped` + `full_scaffold` | Real azurerm / google resources | Still review SKUs and networking |
| `mapped` + `managed_identity_rbac_scaffold` | UAI + placeholder role definition/assignment (Azure) | Thinking IAM actions were fully translated |
| `mapped` + `managed_identity_scaffold` | UAI / service account scaffold | Thinking IAM→full policy was done |
| `mapped` + `profile_scaffold` | Thin profile (CDN / APIM) | Thinking origins/policies were authored |
| `mapped` + `resource_group_only` | Empty-ish RG / project placeholder | Thinking “done” |
| `non_applicable` + `none` | Skip | Filing a bug for “missing” IAM users |

## Source-instance coverage gate

Azure and GCP generation report an instance-weighted `source_coverage_rate` with a **90% target**. The numerator is the applicable AWS managed-resource instances that received a matching destination scaffold; the denominator is all applicable AWS instances, including workload IAM instances. Intentional `non_applicable` source instances are reported separately and excluded from that denominator. Unknown/unsupported source types and mapped types without emitted destination resources remain in the denominator as uncovered. No applicable instances yields `null` coverage and is not a pass. Below-threshold generation still continues: the agent records the rate, writes the gap disposition to `mapping-research.md` / `review-needed.md`, and opens a review-candidate PR. It must not invent IAM bindings to clear 90%, and it must not block the workflow solely because AWS IAM actions, conditions, or trust policies are not yet GCP roles.

`infra_conversion_rate` and `app_iam_conversion_rate` remain diagnostic sub-rates, not substitutes for the all-applicable-source gate. A source instance counts as covered only when the generator emits the category's required destination resource marker; evidence or catalog `status=mapped` alone does not count.

## Generator standards (today)

Deterministic generators (no LLM inventing types):

- Destination naming + baseline security defaults  
- No demo passwords  
- Review-candidate roots only (never apply from the agent)  
- Azure identity: UAI + custom role definition + RG-scoped role assignment scaffold (`managed_identity_rbac_scaffold`)  

**Not** implemented today (expect follow-up work): full landing zones / Fabric / complete IAM→destination action translation, AVM composition, or cross-group topology stitching.

Confidence ≥ **0.7** on identity means the scaffold includes RBAC *shape*, not that AWS IAM statements were converted.

## How to add a new AWS type

1. Add/adjust rows in `mappings/aws-to-azure.json` and/or `mappings/aws-to-gcp.json` with honest `emission`.  
2. If emission needs new HCL shapes, extend the matching `*_iac_generate.py` **with tests**.  
3. Bump catalog `version`.  
4. Bump **`script_pack_version`** in module + `SCRIPT_PACK_VERSION` in `stage-runner.sh` (keep them identical).  
5. Re-apply deployment + **preload** pack on the runner.  
6. Run `azure-migration-pr` / `gcp-migration-pr` on a small fixture group before a large demo.

Checklist: [How to change things](09-how-to-change-things.md).
