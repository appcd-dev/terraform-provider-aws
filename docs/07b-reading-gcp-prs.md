# 7b. How to read GCP PRs

Same review discipline as [Azure PRs](07-reading-azure-prs.md), applied to the `gcp/` tree.

## What the PR should contain

| Path | Expect |
| --- | --- |
| `gcp/groups/<group_id>/` | OpenTofu roots with `google` provider; CAF-analogue naming where the generator emits full scaffolds |
| `gcp/artifacts/migration-blueprint.json` | Per-group mapping decisions |
| `gcp/artifacts/governance-source.json` | Living Nile docs SHA used this run |
| `gcp/artifacts/governance-conformance-report.json` | Must show `conformance_ok` or the PR should not have opened |
| `gcp/artifacts/review-needed.md` | Honest gaps (IAM, landing-zone, unsupported types) |
| Validation / plan notes | `gcp_plan_status` — prefer `success` or `success:sample:N/M`; reject silent “ok” without plan when `require_gcp_live_plan` is on |

## Source coverage gate

Check `gcp/artifacts/generation-summary.json` → `source_coverage_*`. The **90% source-instance coverage target** is converted applicable AWS instances / all applicable AWS instances. App-IAM instances are included; explicit non-applicable instances are reported separately; unsupported or unknown mappings count as uncovered. A `null` rate (no applicable instances) is not a pass. A rate under 90% does not by itself stop the workflow: IAM action/condition/trust translation stays in `review-needed.md`, and the PR is still a review candidate. Infra-only and app-IAM conversion diagnostics have narrower denominators and are not total coverage.

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
