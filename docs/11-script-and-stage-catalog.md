<!-- generated: do not edit by hand — run `make catalog` from repo root -->

# 11. Script and stage catalog

Auto-generated index of workflow stages, execute-series templates, runner scripts, and Python helpers. Use this when tracing a failed stage or finding which file to change.

_Auto-generated. Regenerate with `make catalog` from repo root._


## Stage traceability matrix

How a Guild stage reaches deterministic code on the runner:

```text
workflows_*.tf stage note → stage_context.tf + *.tftpl → LLM paste execute_series
  → run-destination-stage.sh (destination stages) OR stage-runner.sh directly (discovery)
  → cmd_* in stage-runner.sh → Python helpers
```

Log files for destination stages: `$HOME/.<workflow_run_id>/.work/logs/<stage>.log`

### Discovery workflow (`aws-cloud-discovery`)

| Stage | execute_series template | Runner entry | stage-runner cmd | Key notes / outputs |
| --- | --- | --- | --- | --- |
| `runner-capability-preflight` | `runner-capability-preflight-execute-series.sh.tftpl` | direct `stage-runner.sh preflight` | `cmd_preflight` | `runner_capability_preflight_ok` |
| `cloud2code-scan-aws` | `cloud2code-aws-scan-execute-series.sh.tftpl` | `ensure_cloud2code.sh` + cloud2code | (bootstrap) | `monolith_state_uri`, scan artifacts |
| `ingest-and-split` | `ingest-execute-series-embedded.sh.tftpl` | `stage-runner.sh ingest-and-split` | `cmd_ingest_and_split` | split manifest, `aws/groups/` |
| `registry-and-import-codegen` | (agent + SOP) | `stage-runner.sh registry-scaffold` | `cmd_registry_scaffold` | registry scaffold |
| `shell-converge-matrix` | `converge-execute-series-embedded.sh.tftpl` | `stage-runner.sh hydrate-and-plan-matrix` | `cmd_hydrate_and_plan_matrix` | plan matrix, converge status |
| `orphans-secondary-pipeline` | (spawn orphan workflow) | — | — | hands off to orphan workflow |
| `final-gate-and-memory` | (evidence gate) | — | — | discovery evidence checklist; optional orphan handoff |

Gate and loop stages (`*-blocked-gate`, `*-loop`) are LLM evidence checks; they do not invoke new scripts.

### Azure-only workflow (`azure-migration-pr`)

| Stage | execute_series template | `run-destination-stage.sh` | stage-runner cmd | Key notes / outputs |
| --- | --- | --- | --- | --- |
| `azure-source-fetch` | `azure-source-fetch-execute-series-embedded.sh.tftpl` | `azure-source-fetch` | `cmd_azure_source_fetch` | `source_iac_branch`, `aws/groups/` in work root |
| `azure-migration-blueprint` | `azure-migration-blueprint-execute-series-embedded.sh.tftpl` | `azure-migration-blueprint` | `cmd_azure_migration_blueprint` | `azure/artifacts/migration-blueprint.json` |
| `azure-iac-generate` | `azure-iac-generate-execute-series-embedded.sh.tftpl` | `azure-iac-generate` | `cmd_azure_iac_generate` | `azure_iac_generated=true`, `azure/groups/` |
| `azure-iac-validate` | `azure-iac-validate-execute-series-embedded.sh.tftpl` | `azure-iac-validate` | `cmd_azure_iac_validate` | `azure_plan_status=…` |
| `azure-iac-harden` | `azure-iac-harden-execute-series-embedded.sh.tftpl` | `azure-iac-harden` | `cmd_azure_iac_harden` | `azure_iac_harden_ok=true` |
| `azure-iac-governance-conform` | `azure-iac-governance-conform-execute-series-embedded.sh.tftpl` | `azure-iac-governance-conform` | `cmd_azure_iac_governance_conform` | `azure_iac_governance_ok`, governance artifacts |
| `azure-pr` | `azure-pr-execute-series-embedded.sh.tftpl` | `azure-pr` | `cmd_azure_pr` | `azure_pr_url=…` (gated on governance_ok) |
| `azure-only-final` | (evidence gate) | — | — | evidence checklist |

Loop stages: `azure-iac-loop`, `azure-iac-governance-loop`.

### GCP-only workflow (`gcp-migration-pr`)

| Stage | execute_series template | `run-destination-stage.sh` | stage-runner cmd | Key notes / outputs |
| --- | --- | --- | --- | --- |
| `gcp-source-fetch` | `gcp-source-fetch-execute-series-embedded.sh.tftpl` | `gcp-source-fetch` | `cmd_gcp_source_fetch` | `source_iac_branch`, `aws/groups/` in work root |
| `gcp-migration-blueprint` | `gcp-migration-blueprint-execute-series-embedded.sh.tftpl` | `gcp-migration-blueprint` | `cmd_gcp_migration_blueprint` | `gcp/artifacts/migration-blueprint.json` |
| `gcp-iac-generate` | `gcp-iac-generate-execute-series-embedded.sh.tftpl` | `gcp-iac-generate` | `cmd_gcp_iac_generate` | `gcp_iac_generated=true`, `gcp/groups/` |
| `gcp-iac-validate` | `gcp-iac-validate-execute-series-embedded.sh.tftpl` | `gcp-iac-validate` | `cmd_gcp_iac_validate` | `gcp_plan_status=…` |
| `gcp-iac-harden` | `gcp-iac-harden-execute-series-embedded.sh.tftpl` | `gcp-iac-harden` | `cmd_gcp_iac_harden` | `gcp_iac_harden_ok=true` |
| `gcp-iac-governance-conform` | `gcp-iac-governance-conform-execute-series-embedded.sh.tftpl` | `gcp-iac-governance-conform` | `cmd_gcp_iac_governance_conform` | `gcp_iac_governance_ok`, governance artifacts |
| `gcp-pr` | `gcp-pr-execute-series-embedded.sh.tftpl` | `gcp-pr` | `cmd_gcp_pr` | `gcp_pr_url=…` (gated on governance_ok) |
| `gcp-only-final` | (evidence gate) | — | — | evidence checklist |

Loop stages: `gcp-iac-loop`, `gcp-iac-governance-loop`.

### Orphan workflow (`aws-migrator-orphan-iac-module-authoring`)

| Stage | Runner entry | Notes |
| --- | --- | --- |
| `orphan-intake-classify` | LLM + GitHub tools | classify ungrouped resources |
| `scaffold-validate-module` | LLM + runner shell | bootstrap orphan module |
| `memory-and-handoff` | evidence gate | handoff notes |

### Governance codify workflow (`governance-rules-codify`)

| Stage | execute_series template | Runner entry | Notes |
| --- | --- | --- | --- |
| `rules-intake` | `codify-intake-execute-series.sh.tftpl` | GitHub `execute_series` (no runner) | dual-clone source + target repos |
| `rules-codify` | `codify-branch-execute-series.sh.tftpl` | GitHub tools | write Rego under `rules/` |
| `rules-pr` | `codify-pr-execute-series.sh.tftpl` | GitHub tools | open PR, poll GHA `rules-validate` |

## `run-destination-stage.sh` cases (auto-extracted)

| Stage case | Log file |
| --- | --- |
| `gcp-source-fetch` | `.work/logs/gcp-source-fetch.log` |
| `gcp-migration-blueprint` | `.work/logs/gcp-migration-blueprint.log` |
| `gcp-iac-generate` | `.work/logs/gcp-iac-generate.log` |
| `gcp-iac-harden` | `.work/logs/gcp-iac-harden.log` |
| `gcp-iac-governance-conform` | `.work/logs/gcp-iac-governance-conform.log` |
| `gcp-iac-validate` | `.work/logs/gcp-iac-validate.log` |
| `gcp-pr` | `.work/logs/gcp-pr.log` |
| `azure-source-fetch` | `.work/logs/azure-source-fetch.log` |
| `azure-migration-blueprint` | `.work/logs/azure-migration-blueprint.log` |
| `azure-iac-generate` | `.work/logs/azure-iac-generate.log` |
| `azure-iac-harden` | `.work/logs/azure-iac-harden.log` |
| `azure-iac-governance-conform` | `.work/logs/azure-iac-governance-conform.log` |
| `azure-iac-validate` | `.work/logs/azure-iac-validate.log` |
| `azure-pr` | `.work/logs/azure-pr.log` |

## `stage-runner.sh` cmd_* functions (auto-extracted)

| Function | Dispatch name |
| --- | --- |
| `cmd_cleanup_old_runs` | — |
| `cmd_preflight` | — |
| `cmd_download_state` | — |
| `cmd_discover_anchors` | — |
| `cmd_allocate_manifest` | — |
| `cmd_extract_group_states` | — |
| `cmd_materialize_tfstate_splitter_sop_scripts` | — |
| `cmd_resolve_tfstate_splitter_workspace` | — |
| `cmd_run_tfstate_splitter_sop_script` | — |
| `cmd_run_tfstate_monolith_decomposer` | — |
| `cmd_evaluate_split_quality` | — |
| `cmd_tuned_split_manifest` | — |
| `cmd_ingest_and_split` | — |
| `cmd_split_manifest` | — |
| `cmd_count_reconcile` | — |
| `cmd_clone_iac_repo` | — |
| `cmd_azure_source_fetch` | — |
| `cmd_registry_scaffold` | — |
| `cmd_sync_groups_to_repo` | — |
| `cmd_sync_hydrated_iac_pr` | — |
| `cmd_prepare_parallel_artifacts` | — |
| `cmd_hydrate_and_plan_matrix` | — |
| `cmd_azure_migration_blueprint` | — |
| `cmd_azure_iac_generate` | — |
| `cmd_destination_iac_harden` | — |
| `cmd_azure_iac_harden` | — |
| `cmd_gcp_iac_harden` | — |
| `cmd_destination_iac_governance_conform` | — |
| `cmd_azure_iac_governance_conform` | — |
| `cmd_gcp_iac_governance_conform` | — |
| `cmd_destination_iac_validate` | — |
| `cmd_azure_iac_validate` | — |
| `cmd_azure_pr` | — |
| `cmd_gcp_source_fetch` | — |
| `cmd_gcp_migration_blueprint` | — |
| `cmd_gcp_iac_generate` | — |
| `cmd_gcp_iac_validate` | — |
| `cmd_gcp_pr` | — |
| `cmd_commit_pr` | — |
| `cmd_iac_pr_pipeline` | — |
| `cmd_preflight` | `preflight` |
| `cmd_download_state` | `download-state` |
| `cmd_discover_anchors` | `discover-anchors` |
| `cmd_allocate_manifest` | `allocate-manifest` |
| `cmd_extract_group_states` | `extract-group-states` |
| `cmd_split_manifest` | `split-manifest` |
| `cmd_ingest_and_split` | `ingest-and-split` |
| `cmd_count_reconcile` | `count-reconcile` |
| `cmd_cleanup_old_runs` | `cleanup-old-runs` |
| `cmd_clone_iac_repo` | `clone-iac-repo` |
| `cmd_azure_source_fetch` | `azure-source-fetch` |
| `cmd_registry_scaffold` | `registry-scaffold` |
| `cmd_sync_groups_to_repo` | `sync-groups-to-repo` |
| `cmd_commit_pr` | `commit-pr` |
| `cmd_iac_pr_pipeline` | `iac-pr-pipeline` |
| `cmd_prepare_parallel_artifacts` | `prepare-parallel-artifacts` |
| `cmd_hydrate_and_plan_matrix` | `hydrate-and-plan-matrix` |
| `cmd_sync_hydrated_iac_pr` | `sync-hydrated-iac-pr` |
| `cmd_azure_migration_blueprint` | `azure-migration-blueprint` |
| `cmd_azure_iac_generate` | `azure-iac-generate` |
| `cmd_azure_iac_harden` | `azure-iac-harden` |
| `cmd_azure_iac_governance_conform` | `azure-iac-governance-conform` |
| `cmd_azure_iac_validate` | `azure-iac-validate` |
| `cmd_azure_pr` | `azure-pr` |
| `cmd_gcp_source_fetch` | `gcp-source-fetch` |
| `cmd_gcp_migration_blueprint` | `gcp-migration-blueprint` |
| `cmd_gcp_iac_generate` | `gcp-iac-generate` |
| `cmd_gcp_iac_harden` | `gcp-iac-harden` |
| `cmd_gcp_iac_governance_conform` | `gcp-iac-governance-conform` |
| `cmd_gcp_iac_validate` | `gcp-iac-validate` |
| `cmd_gcp_pr` | `gcp-pr` |

## Script inventory

| Script | Type | Purpose | Unit test |
| --- | --- | --- | --- |
| `allocate_manifest.py` | Python | Deterministic monolith tfstate → logical_group_manifest + per-group state shards. | — |
| `app_iam.py` | Python | Application IAM helpers for acquisition-style AWS → destination migration. | `test_app_iam.py` |
| `aws_discovery_scan_report.py` | Python | Build a durable AWS discovery report from Cloud2Code's scan log and tfstate. | `test_aws_discovery_scan_report.py` |
| `azure_iac_generate.py` | Python | Generate review-candidate Azure Terraform roots from the migration blueprint. | — |
| `azure_mapping_catalog.py` | Python | AWS -> Azure migration mapping catalog resolver. | `test_azure_mapping_catalog.py` |
| `destination_iac_harden.py` | Python | Deterministic lint/security autofix for destination Azure/GCP review-candidate roots. | `test_destination_iac_harden.py` |
| `gcp_iac_generate.py` | Python | Generate review-candidate GCP Terraform roots from the migration blueprint. | `test_gcp_iac_generate_fmt.py` |
| `gcp_mapping_catalog.py` | Python | AWS -> GCP migration mapping catalog resolver. | `test_gcp_mapping_catalog.py` |
| `governance_conform.py` | Python | Harness for Nile living-governance conformance. | `test_governance_conform.py` |
| `governance_opa_check.py` | Python | Run Nile-Factory Rego packs against Terraform plan JSON for generated IaC. | `test_governance_opa_check.py` |
| `hcl_sanity.py` | Python | HCL sanity gates for AWS hydrate and destination validate stages. | `test_hcl_sanity.py` |
| `tfstate_monolith_decomposer.py` | Python | Layered three-tier tfstate → logical_group_manifest + per-group state shards. | — |
| `cloud2code-aws-scan.sh` | Shell | Run cloud2code import aws and emit scan sentinels | — |
| `cloud2code-scan-detach.sh` | Shell | Detach cloud2code import from the execute_* process group so a 30s tool timeout does not SIGKILL it | `test_cloud2code_scan_detach.sh` |
| `ensure_cloud2code.sh` | Shell | Bootstrap cloud2code CLI on runner when absent | `test_ensure_cloud2code.sh` |
| `pack-entry.sh` | Shell | Versioned runner entrypoint for preflight, scan, ingest, iac-pr, converge, destination | — |
| `run-destination-stage.sh` | Shell | One-line Guild execute_series entrypoints for destination stages | — |
| `runner-capability-preflight.sh` | Shell | (shell helper) | — |
| `stage-runner.sh` | Shell | (shell orchestrator) | — |
| `workflow-run-id.sh` | Shell | Shared workflow id check before interpolating $HOME/.<id> | — |
| `agent-pipeline-config/scripts/render-ingest-bootstrap.py` | Python | Render ingest-bootstrap.sh from live module templates. | — |
| `agent-pipeline-config/scripts/generate-script-catalog.sh` | Shell | (shared pipeline script) | — |
| `agent-pipeline-config/scripts/preload-script-pack.sh` | Shell | Preload script pack onto aiden-runner | — |
| `agent-pipeline-config/scripts/upgrade-nile-factory-runner-helm.sh` | Shell | (shared pipeline script) | — |

## Execute-series template inventory (auto-extracted)

| Template | Module | First line (truncated) |
| --- | --- | --- |
| `azure-iac-generate-execute-series-embedded.sh.tftpl` | `aios-agent-aws-migrator` | `export WORKFLOW_RUN_ID='{{workflow_run_id}}' DBSPLIT_EMBEDDED=1 ${runner_pack_entry_invoke} destinat` |
| `azure-iac-governance-conform-execute-series-embedded.sh.tftpl` | `aios-agent-aws-migrator` | `export WORKFLOW_RUN_ID='{{workflow_run_id}}' DBSPLIT_EMBEDDED=1 GOVERNANCE_OPA_MAX_GROUPS='0' NILE_G` |
| `azure-iac-harden-execute-series-embedded.sh.tftpl` | `aios-agent-aws-migrator` | `export WORKFLOW_RUN_ID='{{workflow_run_id}}' DBSPLIT_EMBEDDED=1 DEST_HARDEN_PARALLELISM='${dest_hard` |
| `azure-iac-validate-execute-series-embedded.sh.tftpl` | `aios-agent-aws-migrator` | `export WORKFLOW_RUN_ID='{{workflow_run_id}}' DBSPLIT_EMBEDDED=1 REQUIRE_AZURE_LIVE_PLAN='${require_a` |
| `azure-migration-blueprint-execute-series-embedded.sh.tftpl` | `aios-agent-aws-migrator` | `export WORKFLOW_RUN_ID='{{workflow_run_id}}' DBSPLIT_EMBEDDED=1 ${runner_pack_entry_invoke} destinat` |
| `azure-pr-execute-series-embedded.sh.tftpl` | `aios-agent-aws-migrator` | `export WORKFLOW_RUN_ID='{{workflow_run_id}}' DBSPLIT_EMBEDDED=1 IAC_REPOSITORY_URL='${default_iac_re` |
| `azure-source-fetch-execute-series-embedded.sh.tftpl` | `aios-agent-aws-migrator` | `export SOURCE_PR='' SOURCE_IAC_BRANCH='${azure_only_source_branch}' SOURCE_IAC_REPOSITORY_URL='${def` |
| `cloud2code-aws-scan-execute-series.sh.tftpl` | `aios-agent-aws-migrator` | `set -euo pipefail` |
| `converge-execute-series-embedded.sh.tftpl` | `aios-agent-aws-migrator` | `set -euo pipefail` |
| `gcp-iac-generate-execute-series-embedded.sh.tftpl` | `aios-agent-aws-migrator` | `export WORKFLOW_RUN_ID='{{workflow_run_id}}' DBSPLIT_EMBEDDED=1 ${runner_pack_entry_invoke} destinat` |
| `gcp-iac-governance-conform-execute-series-embedded.sh.tftpl` | `aios-agent-aws-migrator` | `export WORKFLOW_RUN_ID='{{workflow_run_id}}' DBSPLIT_EMBEDDED=1 GOVERNANCE_OPA_MAX_GROUPS='0' NILE_G` |
| `gcp-iac-harden-execute-series-embedded.sh.tftpl` | `aios-agent-aws-migrator` | `export WORKFLOW_RUN_ID='{{workflow_run_id}}' DBSPLIT_EMBEDDED=1 DEST_HARDEN_PARALLELISM='${dest_hard` |
| `gcp-iac-validate-execute-series-embedded.sh.tftpl` | `aios-agent-aws-migrator` | `export WORKFLOW_RUN_ID='{{workflow_run_id}}' DBSPLIT_EMBEDDED=1 REQUIRE_GCP_LIVE_PLAN='${require_gcp` |
| `gcp-migration-blueprint-execute-series-embedded.sh.tftpl` | `aios-agent-aws-migrator` | `export WORKFLOW_RUN_ID='{{workflow_run_id}}' DBSPLIT_EMBEDDED=1 ${runner_pack_entry_invoke} destinat` |
| `gcp-pr-execute-series-embedded.sh.tftpl` | `aios-agent-aws-migrator` | `export WORKFLOW_RUN_ID='{{workflow_run_id}}' DBSPLIT_EMBEDDED=1 ${runner_pack_entry_invoke} destinat` |
| `gcp-source-fetch-execute-series-embedded.sh.tftpl` | `aios-agent-aws-migrator` | `export SOURCE_PR='' SOURCE_IAC_BRANCH='${gcp_only_source_branch}' WORKFLOW_RUN_ID='{{workflow_run_id` |
| `iac-pr-execute-series-embedded.sh.tftpl` | `aios-agent-aws-migrator` | `set -euo pipefail` |
| `ingest-execute-series-embedded.sh.tftpl` | `aios-agent-aws-migrator` | `set -euo pipefail` |
| `runner-capability-preflight-execute-series.sh.tftpl` | `aios-agent-aws-migrator` | `set -euo pipefail` |
| `codify-branch-execute-series.sh.tftpl` | `aios-agent-governance-codify` | `cd {{CLONE_DIR}} && set -eu && git fetch origin {{BASE_BRANCH}} && SOURCE_SHA='SOURCE_COMMIT_SHA' &&` |
| `codify-checkout-branch-execute-series.sh.tftpl` | `aios-agent-governance-codify` | `set -eu; TGT='{{TARGET_DIR}}'; TGT_REPO='{{TARGET_REPO}}'; BRANCH='CODIFY_BRANCH'; if git -C "$TGT" ` |
| `codify-intake-execute-series.sh.tftpl` | `aios-agent-governance-codify` | `set -eu; SRC='{{SOURCE_DIR}}'; TGT='{{TARGET_DIR}}'; SRC_REPO='{{SOURCE_REPO}}'; TGT_REPO='{{TARGET_` |
| `codify-pr-execute-series.sh.tftpl` | `aios-agent-governance-codify` | `cd {{CLONE_DIR}} && set -eu && BRANCH='{{BRANCH}}' && if git ls-remote --exit-code --heads origin "$` |
| `codify-push-execute-series.sh.tftpl` | `aios-agent-governance-codify` | `cd {{CLONE_DIR}} && set -eu && git push -u origin {{BRANCH}}` |

## Related docs

- [12. I want to…](12-i-want-to.md) — task-oriented navigation
- [04. Workflows & stages](04-workflows-and-stages.md) — stage DAG and governance loop
- [05. LLM vs scripts](05-llm-vs-scripts.md) — what the model does vs deterministic code
- [09. How to change things](09-how-to-change-things.md) — bump script pack version after edits

