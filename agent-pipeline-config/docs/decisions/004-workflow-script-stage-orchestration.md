# ADR 004: Workflow script stages (Nile-Factory consumer)

- **Status:** Proposed
- **Date:** 2026-08-27
- **Normative spec:** [Guild ADR 004 — Workflow script stages with deterministic gates](https://github.com/appcd-dev/stackgen-guild/blob/main/docs/decisions/004-workflow-script-stage-orchestration.md)
- **Diagram:** [workflow-script-orchestration.drawio](https://github.com/appcd-dev/stackgen-guild/blob/main/docs/architecture/workflow-script-orchestration.drawio) (Guild repo, page 2 = `gcp-migration-pr` DAG)

This document is the **consumer supplement** for Nile-Factory `agent-pipeline-config`. It does not redefine the runtime contract; it maps how `gcp-migration-pr` migrates from LLM-orchestrated stages to `runner_script` + `artifact_gate`.

## Why Nile-Factory first

The AWS→GCP migrator already implements the pipeline in scripts:

- Entry: [`modules/aios-agent-aws-migrator/scripts/run-destination-stage.sh`](../modules/aios-agent-aws-migrator/scripts/run-destination-stage.sh)
- Stages: [`modules/aios-agent-aws-migrator/scripts/stage-runner.sh`](../modules/aios-agent-aws-migrator/scripts/stage-runner.sh)
- Workflow (today): [`modules/aios-agent-aws-migrator/workflows_gcp_only.tf`](../modules/aios-agent-aws-migrator/workflows_gcp_only.tf)

Operator input is already minimal (`intent: gcp-migration-pr`, `source_iac_branch`). Stage notes grew large because the Guild runtime did not run scripts or check artifacts. Live failures on ai.dev (skipped harden/governance, empty layout races, PR blocked without OPA report) are orchestration gaps, not missing prompt text.

## Target binding map (`gcp-migration-pr`)

| Current `stage_id` (TF) | Today | Target |
|-------------------------|-------|--------|
| `gcp-source-fetch` | Agent + long note + `evidence_gate` | `runner_script` → `run-destination-stage.sh gcp-source-fetch` + `artifact_gate`: `groups/` non-empty, log `gcp-source-fetch.log` |
| `gcp-migration-blueprint` | Agent | `runner_script` blueprint + gate: blueprint group count > 0 |
| `gcp-iac-generate` | Agent | `runner_script` generate + gate: generated group count > 0 |
| `gcp-iac-harden` | Agent | `runner_script` harden + gate: harden log exists, `stage_exit_code=0` |
| `gcp-iac-validate` | Agent | `runner_script` validate + gate: `gcp_iac_validation_ok` in notes |
| `gcp-iac-governance-conform` | Agent (also runs OPA when agent invokes script) | `runner_script` governance-conform + gate: `governance-opa-report.json`, `gcp_iac_governance_ok` |
| `gcp-iac-loop` | `loop_stage` | Keep; GO_BACK target becomes exception agent or re-run prior script stage |
| `gcp-iac-governance-loop` | `loop_stage` | Keep; pairs with governance conform + exception remediation |
| **Exception agent** (new or slimmed `aws_migrator_architect`) | N/A | LLM only when gates fail with OPA denies / ambiguous mapping; short note, targeted `execute_series` fixes |
| `gcp-pr` | Agent | `runner_script` gcp-pr + gate: `pr_url` or explicit `stage_summary:gcp-pr=blocked:*` |
| `gcp-only-final` | Agent summary | Optional agent or `transform`; not on critical path |

Azure-only workflow (`workflows_azure_only.tf`) follows the same pattern with `azure-*` stage names.

## Script pack contract (unchanged, but gate-relevant)

| Item | Location |
|------|----------|
| Version pin | `local.script_pack_version` in [`main.tf`](../modules/aios-agent-aws-migrator/main.tf) (e.g. `20260827.4`) |
| Runner preload | [`scripts/preload-script-pack.sh`](../scripts/preload-script-pack.sh) → `$HOME/.aws-migrator/script-pack/<version>/` |
| Version assert | Terraform `check "script_pack_version_matches_stage_runner"` |
| Work isolation | `$HOME/.wf-gcp-migration-pr-<run_id>/` (notes.json, `.work/logs/`, `gcp/artifacts/`) |

Runtime script stages must pass `WORKFLOW_RUN_ID` / work root into `run-destination-stage.sh` the same way embedded execute-series templates do today.

## Example Terraform shape (illustrative)

Not implemented until Guild ships `runner_script`. Intended direction:

```hcl
stage_bindings = {
  gcp-iac-harden = {
    stage_id    = "gcp-iac-harden"
    action_type = "runner_script"
    action_config = {
      runner_name     = var.remote_runner_name
      command         = "run-destination-stage.sh gcp-iac-harden ${workflow_run_id}"
      timeout_seconds = 900
      artifact_gates = [
        { kind = "file_exists", path = "${work_root}/.work/logs/gcp-iac-harden.log" },
        { kind = "notes_json",  jq   = ".gcp_iac_harden_ok == true" }
      ]
    }
  }
}
```

Exception agent stage sits after failed governance gate with `loop_stage` GO_BACK.

## Acceptance (R2 parity)

After migration, a **serialized** `gcp-migration-pr` run with `fixture/opa-gcp-source-mini` must:

1. Execute every script stage on the runner (logs under `.work/logs/` for source-fetch, harden, governance-conform).
2. Produce `gcp/artifacts/governance-opa-report.json` when OPA runs (R2 reference traces `9f07ab23…`).
3. End with either `pr_url` / `gcp_pr_url` in notes or an explicit block (`stage_summary:gcp-pr=blocked:governance_nonconformant`) **with** governance artifacts present (no silent skip).
4. Not depend on agent `read_notes` for upstream skip decisions; `conditional_skip` reads gate results or notes keys written by scripts only.

Blackbox validation: trigger workflow via Guild chat or API, inspect session notes and runner workdir paths listed in stage output.

## Migration phases

1. **Guild:** `runner_script` + `artifact_gate` executors + OpenAPI (blocking).
2. **Nile:** Convert fetch → blueprint → generate → harden → validate (no LLM on happy path).
3. **Nile:** Governance conform as script stage; retain loop + exception agent for OPA deny remediation.
4. **Nile:** PR stage as script; shrink `aws_migrator_architect` persona to exception-only.
5. **Cleanup:** Remove embedded execute-series tftpl blobs from stage notes where redundant.

## Related interim hardening (pre-ADR)

Script pack `20260827.4` added layout normalize, empty-group blocks, and stricter Terraform evidence gates. That work remains valid; script stages will call the same `stage-runner.sh` logic with host-enforced invocation.

## References

- Guild ADR 004: https://github.com/appcd-dev/stackgen-guild/blob/main/docs/decisions/004-workflow-script-stage-orchestration.md
- Diagram: https://github.com/appcd-dev/stackgen-guild/blob/main/docs/architecture/workflow-script-orchestration.drawio
