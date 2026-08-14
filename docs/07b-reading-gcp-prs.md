# 7b. How to read GCP PRs

Same review discipline as [Azure PRs](07-reading-azure-prs.md), applied to the `gcp/` tree.

## What the PR should contain

| Path | Expect |
| --- | --- |
| `gcp/groups/<group_id>/` | OpenTofu roots with `google` provider; CAF-analogue naming where the generator emits full scaffolds |
| `gcp/artifacts/migration-blueprint.json` | Per-group mapping decisions |
| `gcp/artifacts/review-needed.md` | Honest gaps (IAM, landing-zone, unsupported types) |
| Validation / plan notes | `gcp_plan_status` — prefer `success` or `success:sample:N/M`; reject silent “ok” without plan when `require_gcp_live_plan` is on |

## Emission honesty

Do **not** treat every `google_*` resource block as a full AWS equivalent. Catalog rows carry `emission`:

| Emission | Meaning |
| --- | --- |
| `full_scaffold` | Best-effort resource body with baseline security defaults |
| `managed_identity_scaffold` | Service-account style scaffold (not full IAM policy) |
| `profile_scaffold` | Shape/profile only |
| `resource_group_only` | Project/folder placeholder |
| `none` | Explicitly not emitted — must appear in review-needed |

## Live plan

When runner GCP ADC is wired (`GOOGLE_APPLICATION_CREDENTIALS_JSON`, `GCP_PROJECT_ID`, optional `GCP_REGION`):

- Validate runs live `tofu plan` (never apply).
- Large inventories may sample groups → `success:sample:N/M`.
- Missing credentials with `require_gcp_live_plan=true` must fail closed (`skipped:missing_credentials` is not success).

## Dual destinations

A full discovery run can open **both** an Azure PR under `azure/` and a GCP PR under `gcp/` from the same AWS split branch. Review each destination independently; they do not share emission catalogs.
