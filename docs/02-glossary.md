# 2. Glossary

## Jargon → plain English (quick reference)

| When you see… | Think… |
| --- | --- |
| `execute_series` | Shell the LLM pastes; runs preloaded script-pack commands on the runner |
| `script pack` | Versioned copy of `stage-runner.sh` + Python on the runner |
| `aios-*` | OpenTofu module prefix for StackGen pipeline config |
| `AppStack` | StackGen resource grouping; destination-only runs must not create these |
| `codify` | Offline workflow: governance markdown → Rego rules in `rules/` |
| `conform` | Per-run check against live Governance-and-Policy docs |
| `DBSPLIT_EMBEDDED` | Env flag required to invoke `stage-runner.sh` (work-dir isolation) |
| `living Nile governance` | Each run refreshes external docs and builds a run-specific validator |
| `docs/nile-governance/` | Human browse pin only; runtime conform fetches live from GitHub |

Full definitions below. Task navigation: [12. I want to…](12-i-want-to.md).

## Terms

| Term | Meaning |
| --- | --- |
| **StackGen / Aiden OS / Guild** | Product that hosts agents, workflows, integrations, vault secrets, and remote runners |
| **Workspace / project / orgId** | Tenant slice you target with `stackgen_project_id` |
| **Agent** | LLM persona + tools (shell on runner, GitHub, AWS MCP, …) |
| **Workflow** | Ordered **stages** with guards, loops, and evidence checklists |
| **Stage** | One step in a workflow (e.g. `azure-iac-generate`) |
| **Remote runner** | VM/pod that runs shell tools outbound to StackGen |
| **Script pack** | Files under `/home/runner/.aws-migrator/script-pack/<version>/` — sha256-gated copies of `stage-runner.sh`, Python helpers, catalog |
| **`script_pack_version`** | Version string in module `main.tf` + `SCRIPT_PACK_VERSION` in `stage-runner.sh` — bump **both** when pack files change |
| **cloud2code** | StackGen CLI that discovers AWS and emits Terraform state |
| **Monolith state** | Single large `terraform.tfstate` before split |
| **Logical group / shard** | One bag of related resources → one folder under `aws/groups/<id>/` |
| **Reverse-IaC** | HCL written so `tofu plan` against live AWS shows zero drift |
| **Mapping catalog** | `mappings/aws-to-azure.json` — AWS Terraform type → Azure decision |
| **`status=mapped`** | Catalog has a target type (or class). **Not** “full HCL emitted” |
| **`emission`** | What generate actually wrote (`full_scaffold`, `managed_identity_rbac_scaffold`, `managed_identity_scaffold`, `profile_scaffold`, `resource_group_only`, `none`, …) |
| **Blueprint** | `azure/artifacts/migration-blueprint.json` — per-group decisions before HCL write |
| **Review-candidate** | PR-grade Azure scaffold; not apply-ready landing zone |
| **CAF** | Microsoft Cloud Adoption Framework naming/landing-zone ideas |
| **WAF (Azure)** | Well-Architected Framework security/reliability guidance |
| **AVM** | Azure Verified Modules — **not** fully composed by this generator today |
| **Live plan** | `tofu plan` against a real Azure subscription (Reader SP) |
| **Sample plan** | Live plan on only N groups (`AZURE_LIVE_PLAN_MAX_GROUPS`) — must be disclosed in the PR |
| **source-instance coverage** | Destination scaffolded applicable AWS managed instances / all applicable AWS managed instances; 90% generation gate for Azure/GCP; non-applicable instances reported separately; unknown/unsupported remain uncovered |
| **`require_azure_live_plan`** | If true, missing ARM_* credentials **fail** validate (no soft skip) |
| **dangerous-ops policy** | Rego that forces HITL on destructive/off-hours shell |
| **Evidence** | Checklist items the final stage must prove (`azure_pr_url_recorded`, …) |
| **Notes** | Key/value facts the agent records between stages (`azure_iac_generated=true`) |
| **walmart** | Customer-managed deployment root under `deployments/walmart/` (Nile-Staging) |
| **greenfield** | TF-owned empty-workspace bring-up under `deployments/greenfield/` (formerly `walle`) |

## Emission cheat sheet

| Emission | Human reading |
| --- | --- |
| `full_scaffold` | Category got real azurerm resources (still review SKUs/CIDRs/keys) |
| `managed_identity_rbac_scaffold` | UAI + placeholder role definition/assignment; IAM actions still need translation |
| `managed_identity_scaffold` | Only user-assigned identity / service account; RBAC not auto-authored |
| `profile_scaffold` | Thin profile (e.g. Front Door / APIM) — deep follow-up needed |
| `resource_group_only` | Placeholder RG + notes |
| `none` | Type is non_applicable / skipped |

## Status strings you will see

| Value | Meaning |
| --- | --- |
| `azure_plan_status=success` | Live plan ran on **all** validated groups that were planned |
| `azure_plan_status=success:sample:8/380` | Live plan OK on **8 of 380** — not full coverage |
| `skipped:missing_credentials` | No ARM_* on runner; hard fail when live plan is required |
| `preload_sha256_mismatch` | Runner pack ≠ module version — re-preload after bump |
