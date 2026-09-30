# 7. Reading Azure migration PRs

Use this checklist so “green” demos do not fool you.

## 1. Read the PR body for honesty

Look for:

- Group counts (**N** groups generated)  
- Whether live plan is **sample** (`success:sample:8/380`) vs full  
- Explicit “review-candidate / do not apply” language  

If the body claims “all groups planned successfully” but notes say `sample`, trust the notes.

## 2. Open `azure/artifacts/`

Typical files:

| File | Why it matters |
| --- | --- |
| `migration-blueprint.json` | Per-group mapping decisions + group confidence |
| `governance-source.json` | Living Nile docs repo/ref/**SHA** used this run (not the submodule pin) |
| `governance-conformance-report.json` | `conformance_ok` + iteration; PR should not exist if this is false |
| `governance-exceptions.md` | Blocking residuals only — not human approval |
| `validation-report.json` | Which groups got fmt/validate/plan |
| Catalog / emission summaries | How many `full_scaffold` vs `managed_identity_rbac_scaffold` vs placeholders |

Ask: did validate cover **all** groups or a **cap** (`AZURE_VALIDATE_MAX_GROUPS` / `AZURE_LIVE_PLAN_MAX_GROUPS`)?

### Group confidence

- Group `confidence` averages only decisions that still affect generation (`status != non_applicable`, `emission != none`).
- `confidence_reason=non_applicable_only` means the group was Entra/folded types only — still review, but do not treat it as a “failed mapping”.
- Confidence ≥ **0.7** on identity means UAI + placeholder RBAC shape (`managed_identity_rbac_scaffold`), **not** full IAM action translation.

## 3. Spot-check HCL quality

Pick three groups:

1. One networking-ish (`full_scaffold`)  
2. One identity-ish (`managed_identity_rbac_scaffold` — expect UAI + role definition + assignment)  
3. One placeholder / profile (`resource_group_only` or `profile_scaffold`)

Verify:

- No committed `*.out` / `.terraform/` noise  
- No default passwords  
- Names look CAF-ish  
- Placeholder groups have clear comments/notes  
- Identity role definitions still say “replace permissions”  

## 4. Source coverage gate

Check `azure/artifacts/generation-summary.json` → `source_coverage_*`. A generated Azure PR must pass the **90% source-instance coverage gate**: converted applicable AWS instances / all applicable AWS instances. Identity/app-IAM instances are included; explicit non-applicable instances are reported separately; unsupported or unknown mappings count as uncovered. A `null` rate (no applicable instances) is not a pass. Infra-only and app-IAM conversion diagnostics have narrower denominators and must not be quoted as total migration coverage.

## 5. Do not equate metrics

| Metric | Safe interpretation |
| --- | --- |
| “380 groups” | Split produced 380 folders — not 380 complete Azure apps |
| `mapped` count | Catalog coverage — not emission depth |
| Group confidence ≥ 0.7 | Applicable scaffolds meet the bar — not apply-ready |
| `validation true` | Often “sampled validate/plan OK” — read the report |
| PR opened | Workflow finished — not production-ready landing zone |

## 6. Known honest gaps

Call these out in review comments instead of silently approving:

- Identity RBAC permissions are placeholders (actions still need translation)  
- CDN / API Gateway (`profile_scaffold`) and ECS-class approximations  
- Empty `attribute_mapping` for many identity rows  
- Sampled live plan  

## 7. After catalog / generator bumps

Bump `script_pack_version` and **re-preload** the runner pack before expecting new confidence scores. Stale packs still emit old UAI-only / unsupported placeholders.

## 8. Example review comment

> Validate report only plans 8/380 (`success:sample:8/380`). Identity groups emit UAI + placeholder RBAC (emission=`managed_identity_rbac_scaffold`); permissions still need translation. Networking group `…` looks review-candidate (TLS/NSG OK). **Not** apply-ready.
