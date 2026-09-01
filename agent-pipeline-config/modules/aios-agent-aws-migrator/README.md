# aios-agent-aws-migrator

Guild agent workflows for **AWS cloud discovery** plus destination **Azure** / **GCP** migration PRs. Three workflows:

| Workflow | Intent | Role |
|----------|--------|------|
| `aws-cloud-discovery` | `aws-cloud-discovery` | cloud2code → split → reverse HCL → **one multi-commit AWS PR** (`discovery/<run_id>`) |
| `azure-migration-pr` | `azure-migration-pr` | handoff via `source_pr` or `source_iac_branch` → Azure blueprint/HCL/TODO/plan → **sibling multi-commit Azure PR** |
| `gcp-migration-pr` | `gcp-migration-pr` | same contract for GCP |

Catalogs stay destination-specific (`mappings/aws-to-azure.json`, `mappings/aws-to-gcp.json`).

**Naming:** see [NAMING.md](NAMING.md) (agent vs cloud vs destination scopes).

**Docs:** [docs hub](../../../docs/README.md) — especially [LLM vs scripts](../../../docs/05-llm-vs-scripts.md), [reading Azure PRs](../../../docs/07-reading-azure-prs.md), and [reading GCP PRs](../../../docs/07b-reading-gcp-prs.md).

Pipeline summary:

1. **`aws-cloud-discovery`:** Run `cloud2code import aws` for a full AWS region.
2. Treat the generated `terraform.tfstate` as the monolithic state input.
3. Split that state into smaller logical project groups.
4. Score split quality and tune/rerun when weak.
5. Reverse-engineer HCL for each generated state/root; converge sampled groups to zero-change plans.
6. Open **one multi-commit discovery PR** on branch `discovery/<run_id>` (report → tfstate → blueprint → split report → terraform → TODO). Hydrate may add a follow-up commit on the same PR.
7. **`azure-migration-pr` / `gcp-migration-pr` (separate runs):** operator passes `source_pr` or `source_iac_branch` from the discovery PR tip.
8. Generate review-candidate destination roots under `azure/groups/` or `gcp/groups/` from the mapping catalogs.
9. Statically validate; live-plan a disclosed sample when credentials are configured (never apply).
10. Open a **sibling multi-commit destination PR** (blueprint → terraform → TODO → plan).

## Requirements

- StackGen provider `>= 0.1.25, < 0.2.0`.
- Optional `model_names` from `aios-foundation` or `aios-foundation-bedrock`. Leave it empty to use Guild's built-in default model provider.
- `policy_ids.dangerous_ops` from `aios-policies`.
- GitHub integration credentials: pass `github_secret_id` or `existing_github_integration_name`.
- AWS integration credentials: pass `aws_secret_id` or `existing_aws_integration_name`.
- Remote runner with `aws`, `jq`, `git`, `tar`, either `curl` or `wget`, and `tofu` or `terraform` installed. When `cloud2code` is absent, the scan bootstrap downloads pinned version `0.5.1` from `releases.stackgen.com` into `$HOME/.local/bin`; root access is not required. Install `tflint` when lint enforcement is desired. Azure/GCP credentials are optional for the demo; missing credentials skip live destination plan only (unless `require_*_live_plan` is on).

The module creates and attaches a remote runner by default. Use the `remote_runner_cli_start_command_with_secrets` or `remote_runner_helm_install_command` output to start the runner before invoking the workflow. Preload the tfstate decomposition script pack on the runner under `/home/runner/.aws-migrator/script-pack/<script_pack_version>`; do not pass the large scripts through runner environment variables, because an oversized runner environment can make every `sh -c` command fail with `E2BIG`.

The preloaded script pack must include `allocate_manifest.py`, `tfstate_monolith_decomposer.py`, `stage-runner.sh`, `ingest-bootstrap.sh`, Azure + GCP catalog/generator scripts, `destination_iac_harden.py`, `governance_conform.py`, and mapping catalogs (`aws-to-azure.json`, `aws-to-gcp.json`). Each file is sha256-gated: bumping a catalog (or any pack file) requires bumping `local.script_pack_version` and re-preloading, otherwise the runner fails loudly with `script_pack_error=preload_sha256_mismatch`. Validate catalog edits offline with `python3 scripts/test_azure_mapping_catalog.py` and `python3 scripts/test_gcp_mapping_catalog.py`. Living-gov harness tests: `python3 scripts/test_governance_conform.py`.

## Runner Credentials

For cloud2code and plan hydration, the runner needs AWS read credentials for the target region. The simplest path is to pass:

```hcl
runner_aws_access_key_id     = var.aws_readonly_access_key_id
runner_aws_secret_access_key = var.aws_readonly_secret_access_key
runner_aws_region            = "us-east-1"
```

For cloning or opening a PR in an IaC repository, pass `runner_git_token` or a pre-existing `runner_git_env_secret_id` with flat `GIT_TOKEN`, `GIT_HOST`, and `GIT_USERNAME` metadata.

## Usage

```hcl
module "aws_migrator" {
  source = "github.com/appcd-dev/solutions//modules/aios-agent-aws-migrator?ref=main"

  # Optional: omit model_names to use Guild's built-in default provider.
  policy_ids = { dangerous_ops = module.policies.policy_ids.dangerous_ops }

  github_secret_id = module.github_integration.secret_id
  aws_secret_id    = module.aws_integration.secret_id

  create_remote_runner = true
  runner_git_token     = var.git_token

  runner_aws_access_key_id     = var.aws_readonly_access_key_id
  runner_aws_secret_access_key = var.aws_readonly_secret_access_key
  runner_aws_region            = "us-east-1"
}
```

## Workflow

Primary workflow: `aws-cloud-discovery`

Azure destination PR workflow: `azure-migration-pr`

GCP destination PR workflow: `gcp-migration-pr`

Destination PR workflows skip cloud2code, tfstate split, AWS HCL hydration, and orphan handling. They resolve `source_pr` (preferred) or `source_iac_branch` (fallback default `azure_only_source_branch` / `gcp_only_source_branch`) from `default_iac_repository_url`, restore `aws/groups` plus `aws/artifacts`, then run destination blueprint, generation, validation, living Nile governance conform, and a sibling PR gated on `*_iac_governance_ok`.

Required workflow input:

- `aws_region`

Optional workflow inputs:

- `cloud2code_include` - comma-separated Terraform AWS resource types. Empty means full-region scan.
- `cloud2code_exclude` - comma-separated resource types to omit.
- `cloud2code_tags` - comma-separated `Key:Value` tag filters.
- `cloud2code_output_dir` - runner-local output directory.
- `cloud2code_discovery_name` - optional local discovery/output name. The runner always uses `cloud2code --auto-import=false`.
- `iac_repository_url` / `iac_repo_url` - optional repo to receive grouped Terraform roots and artifacts.
- `default_branch`, `grouping_policy_json`, `grouping_strategy`, `max_resources_per_appstack`.
- Decomposer tuning: `tfstate_decomposer_env_scope`, `tfstate_decomposer_env_tag_keys`, `tfstate_decomposer_layer3_tag_keys`, `tfstate_decomposer_skip_unknown_type_review`, `tfstate_decomposer_overrides_json` / `_path`, `tfstate_decomposer_layer_taxonomy_json`, and `tfstate_decomposer_max_tuning_iterations`.

The default split path is `tfstate_monolith_decomposer.py`. The runner scores each candidate, reruns with tuned controls when useful, and selects the best result by count reconciliation first, then quality score, then lowest orphan count. Clean pass requires `quality_score >= 80` with no hard issues; after bounded tuning a best candidate may soft-pass at `quality_score >= 70` with no hard issues (`selection_reason=best_candidate_after_bounded_tuning`). Soft-pass is acceptable, not excellent.

Runner work is namespaced under `$HOME/.<workflow_run_id>/` so one remote runner can support concurrent runs. `stage-runner.sh preflight` writes `.active` / `.last_touch` sentinels and runs TTL cleanup for old sibling run directories (`DBSPLIT_RUN_TTL_HOURS`, default `48`). Set `DBSPLIT_RUN_CLEANUP_ON_PREFLIGHT=0` to disable or `DBSPLIT_CLEANUP_DRY_RUN=true` to audit candidates.

Stage shape (`aws-cloud-discovery`):

```text
runner-capability-preflight
 -> preflight-blocked-gate
 -> cloud2code-scan-aws
 -> cloud2code-scan-loop
 -> scan-blocked-gate
 -> ingest-and-split
 -> ingest-split-loop
 -> ingest-blocked-gate
 -> registry-and-import-codegen
 -> shell-converge-matrix
 -> shell-converge-loop
 -> converge-blocked-gate
 -> orphans-secondary-pipeline
 -> final-gate-and-memory
```

Blocked gates are platform `conditional_skip` stages (no LLM). When a terminal `blocked:*` sentinel matches, the gate jumps to `final-gate-and-memory`.

Destination Azure/GCP PRs are **not** stages of this workflow. Run `azure-migration-pr` / `gcp-migration-pr` separately with `source_pr` or `source_iac_branch` from the discovery PR.

Azure / GCP destination stage shape (`azure-migration-pr` / `gcp-migration-pr`):

```text
*-source-fetch
 -> *-migration-blueprint
 -> *-iac-generate
 -> parallel: *-iac-validate, *-iac-harden, *-iac-governance-conform
 -> *-iac-loop / *-iac-governance-loop
 -> *-pr
 -> *-only-final
```

## Evidence

The discovery workflow checklist requires AWS reverse-IaC proof only (`cloud2code_tfstate_recorded`, `iac_pr_url_recorded`, plan zero-diff evidence, etc.). See `sg_evidence_checklist.aws_migrator_discovery_evidence` in `main.tf`.

Azure and GCP destination workflows have separate evidence checklists (`azure-migration-pr-evidence`, `gcp-migration-pr-evidence`) covering fetch, blueprint, generate, validate, harden, governance conform, and PR URL.

When `iac_repository_url` is supplied, discovery opens an AWS PR with:

- `aws/groups/<group_id>/` - per-group source Terraform roots and split state shards
- `aws/artifacts/` - manifests, split quality/tuning reports, review/layer summaries, orphan bundle, registry mapping, sample payloads, and handoff notes

Destination workflows (`azure-migration-pr` / `gcp-migration-pr`) write:

- `azure/groups/<group_id>/` - best-effort Azure Terraform roots (each with a `mapping-decisions.json`)
- `azure/artifacts/` - migration profile, blueprint, aggregated mapping decisions, generation summary, validation report, PR body, and review-needed notes
- `gcp/groups/<group_id>/` - best-effort GCP Terraform roots (same honesty contract via `emission`)
- `gcp/artifacts/` - parallel GCP blueprint / validation / review-needed artifacts

Resource-type mapping is deterministic and catalog-driven via `azure_mapping_catalog.py` / `gcp_mapping_catalog.py`. Types marked `non_applicable` are surfaced as review/skipped rather than scaffolded as fake services; types absent from the catalog resolve as `unsupported`.

The workflow does not create AppStacks and does not call StackGen MCP tools. Ambiguous mappings are documented, not used as human approval gates. When destination runner credentials are wired, live `tofu plan` is required (`require_azure_live_plan` / `require_gcp_live_plan`); the pipeline never applies migrated destination resources.

## Outputs

See `outputs.tf` for agent/workflow names, remote runner install commands, runner secret IDs, integration names, and optional webhook values.
