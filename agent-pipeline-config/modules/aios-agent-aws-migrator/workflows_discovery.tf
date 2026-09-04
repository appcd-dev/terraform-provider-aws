# =============================================================================
# Primary workflow — AWS region scan → decomposed TF states + plan convergence
# =============================================================================

resource "sg_workflow" "aws_migrator_discovery" {
  name        = local.workflow_primary_name
  domain      = "infrastructure-as-code"
  description = <<-EOT
    AWS cloud discovery. Runs **cloud2code** against one AWS region to synthesize a Terraform state,
    splits that state into logical project groups (with quality scoring/tuning), reverse-engineers HCL,
    loops until sampled Terraform plans converge, then opens **one multi-commit discovery PR** on
    `discovery/<workflow_run_id>` (report → tfstate → migration blueprint → split report → terraform → TODO).
    Destination Azure/GCP migration PRs are **separate** workflows (`azure-migration-pr` / `gcp-migration-pr`)
    that take `source_pr` or `source_iac_branch` as handoff — they are not stages of this workflow.
    Cross-stage scratch paths use `$HOME/.<workflow_run_id>/` — copy `workflow_run_id` from the stagerunner `[Workflow execution]` header.
    Optional **`tfstate_decomposer_*`** controls tune environment scoping, tag keys, taxonomy, overrides, and max candidate iterations.
    **HCL is fully agent-authored, and only HCL:** the reverse-IaC stage runs `tofu plan -generate-config-out=generated.tf`; every committed source-cloud file under `aws/groups/<group_id>/` is `.tf` (HCL), never `*.tf.json`.
    **Git access** for `git clone iac_repository_url` runs on the **remote runner** with env-mounted credentials (`GIT_TOKEN` / `GIT_HOST` / `GIT_USERNAME` or `GIT_SSH_PRIVATE_KEY` + `GIT_SSH_KNOWN_HOSTS`).
    **Execution Optimization Protocol (hard rule):** multi-step shell work batches into one `${local.shell_tool_prefix}_execute_series`; independent fan-out uses `${local.shell_tool_prefix}_execute_parallel` — never N concurrent `execute_command` calls in a single turn.
    **DAG:** `runner-capability-preflight` → `preflight-blocked-gate` → `cloud2code-scan-aws` → `cloud2code-scan-loop` → `scan-blocked-gate` → `ingest-and-split` → `ingest-split-loop` → `ingest-blocked-gate` → `registry-and-import-codegen` → `shell-converge-matrix` → `shell-converge-loop` → `converge-blocked-gate` → `orphans-secondary-pipeline` → `final-gate-and-memory`. Blocked gates jump to `final-gate-and-memory`.
  EOT
  approve     = true

  metadata = {
    planner_max_tool_iterations = 12
  }

  lifecycle {
    ignore_changes = [
      metadata,
    ]
  }

  required_inputs = ["aws_region"]
  optional_inputs = [
    "cloud2code_include",
    "cloud2code_exclude",
    "cloud2code_tags",
    "cloud2code_output_dir",
    "cloud2code_discovery_name",
    "iac_repository_url",
    "iac_repo_url",
    "default_branch",
    "remote_runner_name",
    "max_convergence_iterations",
    "registry_catalog_url",
    "grouping_policy_json",
    "grouping_strategy",
    "max_resources_per_appstack",
    "tfstate_decomposer_env_scope",
    "tfstate_decomposer_env_tag_keys",
    "tfstate_decomposer_layer3_tag_keys",
    "tfstate_decomposer_skip_unknown_type_review",
    "tfstate_decomposer_overrides_json",
    "tfstate_decomposer_overrides_path",
    "tfstate_decomposer_layer_taxonomy_json",
    "tfstate_decomposer_max_tuning_iterations",
  ]
  evidence_checklist_ref = sg_evidence_checklist.aws_migrator_discovery_evidence.name

  example_queries = [
    "Scan AWS us-east-1 with cloud2code, split the generated tfstate into app projects, reverse HCL, and prove each sampled group has a successful terraform plan",
    "Run cloud2code for us-west-2 (IAM excluded by default), then decompose by tag-seeded connectivity and open a PR with grouped Terraform roots",
    "Scan AWS us-east-1 resources tagged Environment:Production, split the synthesized state into smaller project states, and verify zero-diff plans",
    "Full-region AWS inventory: grouping_strategy=tfstate_monolith_decomposer, max_resources_per_appstack=120, tfstate_decomposer_env_scope=l2l3",
  ]

  triggers = [
    { field = "intent", values = ["aws-cloud-discovery", "aws-cloud2code-discovery", "cloud2code-aws-scan", "aws-region-to-terraform", "aws-brownfield-iac-discovery"], type = "passive" },
  ]

  runbook_refs = [
    sg_runbook_sop.cloud2code_aws_region_scan.name,
    sg_runbook_sop.aws_migrator_orchestration.name,
    sg_runbook_sop.tfstate_splitter.name,
    sg_runbook_sop.terraform_registry_reverse_iac.name,
    sg_runbook_sop.terraform_substate_convergence.name,
    sg_runbook_sop.orphan_iac_module_bootstrap.name,
  ]

  stages = concat(
    [
      {
        stage_id    = "runner-capability-preflight"
        description = "Verify remote-runner tools (jq, aws, python3, git, tofu, cloud2code) and script-pack preload before scan"
        note        = "create_agent OK. Worker pastes printf|/bin/bash one-liner once. Emits runner_capability_preflight_ok or blocked:remote_runner_* . No custom probes."
        required    = true
      },
      {
        stage_id    = "preflight-blocked-gate"
        description = "Skip to final gate when runner capability preflight emitted a blocked sentinel"
        note        = "conditional_skip only — no LLM."
        required    = false
      },
      {
        stage_id    = "cloud2code-scan-aws"
        description = "Run cloud2code import aws for one region and record generated terraform.tfstate"
        note        = "One remote-runner subagent, one execute_series. Writes monolith_state_uri for ingest-and-split."
        required    = true
      },
      {
        stage_id    = "cloud2code-scan-loop"
        description = "Retry cloud2code scan until a valid tfstate handoff or terminal blocked sentinel is emitted"
        note        = "loop_stage only — no LLM. Exit on cloud2code_scan_ok=true or terminal cloud2code blocked sentinel."
        required    = false
      },
      {
        stage_id    = "scan-blocked-gate"
        description = "Skip to final gate when cloud2code scan ended on a terminal blocked sentinel"
        note        = "conditional_skip only — no LLM."
        required    = false
      },
      {
        stage_id    = "ingest-and-split"
        description = "Consume cloud2code tfstate, invoke aws-migrator-tfstate-splitter-sop via tfstate_monolith_decomposer.py, score segregation quality, tune/rerun when needed"
        note        = "One bootstrap command: preflight → download-state → tfstate_monolith_decomposer.py split → scaffold-registry → split quality score/tuning loop. Clean pass requires quality_score>=80; after bounded tuning a best candidate may soft-pass at score>=70 with no hard issues. See aws-migrator-orchestration-sop § *Script pack* and § *Split quality floors*."
        required    = true
      },
      {
        stage_id    = "ingest-split-loop"
        description = "Retry ingest/decomposition until count reconciliation and split quality pass or terminal blocked sentinel is emitted"
        note        = "loop_stage only — no LLM. Exit on count_reconciliation_ok=true plus split_quality_pass=true, or terminal ingest blocked sentinel. script_pack_drift_possible is a warning, not a loop exit."
        required    = false
      },
      {
        stage_id    = "ingest-blocked-gate"
        description = "Skip to final gate when ingest/split ended on a terminal blocked or reconcile failure"
        note        = "conditional_skip only — no LLM. Does not treat script_pack_drift_possible as a skip."
        required    = false
      },
      {
        stage_id    = "registry-and-import-codegen"
        description = "Script-first: registry scaffold + prepare-parallel-artifacts + IaC PR"
        note        = "Runs iac-pr-pipeline (scaffold, batch_payloads.json, clone, cp sync, gh pr). Allocates a fresh branch starting with discovery/<workflow_run_id>; if that branch exists or has PR history, appends a timestamp/PID suffix. Does NOT run tofu hydrate — that is shell-converge-matrix."
        required    = true
      },
      {
        stage_id    = "shell-converge-matrix"
        description = "Script-first: self-repairing hydrate-and-plan-matrix over sample groups (tofu init + generate-config-out + fmt/validate/test/lint/plan)"
        note        = "ONE shell-converge-matrix-runner execute_series. Repairs runner disk/provider-cache init failures, emits hcl_hydration_status:*, hcl_init_status:*, and multi_plan_zero_diff_ok."
        required    = true
      },
      {
        stage_id    = "shell-converge-loop"
        description = "Retry Terraform hydration and validation until every sampled group has zero-diff plan output or a terminal blocker is emitted"
        note        = "loop_stage only — no LLM. Exit on multi_plan_zero_diff_ok=true or terminal validation blocker."
        required    = false
      },
      {
        stage_id    = "converge-blocked-gate"
        description = "Skip to final gate when shell converge ended on a terminal runner/validation blocker"
        note        = "conditional_skip only — no LLM. Prevents orphans fan-out after blocked converge."
        required    = false
      },
      {
        stage_id    = "orphans-secondary-pipeline"
        description = "Parallel layer: trigger orphan-iac-module-authoring when orphans_bundle non-empty"
        note        = "Skip cleanly when orphans_bundle empty. Max 2 tool turns (read_notes + note/notify)."
        required    = false
      },
      {
        stage_id    = "final-gate-and-memory"
        description = "Confirm counts + validation + zero plans; persist orphan_modularization_memory and handoff summary"
        note        = "Merge secondary workflow results if any; final notify / PR / submit_evidence."
        required    = true
      },
    ],
  )

  stage_bindings = [
    {
      stage_id  = "runner-capability-preflight"
      agent_ref = sg_agent.aws_migrator_architect.name
      runbook_refs = [
        sg_runbook_sop.aws_migrator_orchestration.name,
      ]
      skill_refs = concat(
        [local.sop_orchestration_name],
        try(var.workflow_skill_refs["aws-cloud-discovery::runner-capability-preflight"], []),
      )
      note = <<-EOT
        **Purpose:** fail fast when the remote runner lacks tools or the script pack is not preloaded — before cloud2code or ingest burn cost.
        **Incremental bring-up execution:** `create_agent` is allowed (reactree). Spawn ONE preflight worker with CREATE_AGENT_EXPECTATION from the spawn context (exact `bash …/runner-capability-preflight.sh` one-liner in expectation). `tool_names` only `["${local.shell_tool_prefix}_execute_series"]`. Never invent probes — `execute_*` runs under `/bin/sh` (sessions dcfbdaa2 / 6741e13a). If shell tools are absent, emit `blocked:remote_runner_shell_unavailable: "true"` and return.
        **Hard evidence gate:** completion requires `runner_capability_preflight_ok: "true"`. Absent that, record `stage_summary:runner-capability-preflight=blocked:missing_runner_evidence` and return blocked.
        **Blocked sentinels:** `blocked:remote_runner_jq_missing`, `blocked:remote_runner_awscli_missing`, `blocked:remote_runner_python3_missing`, `blocked:remote_runner_git_missing`, `blocked:remote_runner_tofu_missing`, `blocked:remote_runner_opa_missing`, `blocked:remote_runner_cloud2code_missing`, `blocked:remote_runner_script_pack_missing`, `blocked:remote_runner_shell_unavailable`.

        ${local.aws_migrator_spawn_context_preflight}
      EOT
    },
    {
      stage_id         = "preflight-blocked-gate"
      action_type      = "conditional_skip"
      agent_ref        = ""
      stage_depends_on = ["runner-capability-preflight"]
      action_config = {
        condition = "output_matches_regex"
        match     = "blocked:remote_runner_jq_missing|blocked:remote_runner_awscli_missing|blocked:remote_runner_python3_missing|blocked:remote_runner_git_missing|blocked:remote_runner_tofu_missing|blocked:remote_runner_opa_missing|blocked:remote_runner_cloud2code_missing|blocked:remote_runner_script_pack_missing|blocked:remote_runner_shell_unavailable|stage_summary:runner-capability-preflight=blocked:"
        skip_to   = "final-gate-and-memory"
        reason    = "Runner capability preflight failed — skip scan, ingest, destination, and orphan stages"
      }
    },
    {
      stage_id         = "cloud2code-scan-aws"
      stage_depends_on = ["preflight-blocked-gate"]
      agent_ref        = sg_agent.aws_migrator_architect.name
      runbook_refs = [
        sg_runbook_sop.cloud2code_aws_region_scan.name,
        sg_runbook_sop.aws_migrator_orchestration.name,
      ]
      skill_refs = concat(
        [local.sop_cloud2code_scan_name, local.sop_orchestration_name],
        try(var.workflow_skill_refs["aws-cloud-discovery::cloud2code-scan-aws"], []),
      )
      note = <<-EOT
        **Purpose:** create the monolithic AWS Terraform state for this workflow. This stage owns `monolith_state_uri`; downstream stages must not ask the operator for it.
        **Incremental bring-up execution:** `create_agent` is allowed (reactree). Spawn ONE `cloud2code-scan-runner` with CREATE_AGENT_EXPECTATION from the spawn context (exact `bash …/cloud2code-aws-scan.sh` one-liner; replace `AWS_REGION_PLACEHOLDER`). `tool_names` only `["${local.shell_tool_prefix}_execute_series"]`. Never invent `set -o pipefail` / `cloud2code aws scan` (sessions 127f2c35 / af38cc9e).
        **Hard evidence gate:** never report this stage complete from notes or reasoning alone. Completion requires a successful `${local.shell_tool_prefix}_execute_series` result containing `cloud2code_scan_ok: "true"`, a non-empty `monolith_state_uri`, and `monolith_resource_count` greater than zero. If those values are absent, record `stage_summary:cloud2code-scan-aws=blocked:missing_runner_evidence` and return blocked.
        **No Azure generation here:** this stage only creates the source AWS tfstate. Azure generation starts after AWS HCL convergence.
        **Success criteria:** final line must include `cloud2code_scan_ok: "true"`, `cloud2code_tfstate_path=...`, `monolith_state_uri=...`, and `monolith_resource_count=<N>`. Also `note` those keys and mirror them to `$HOME/.<workflow_run_id>/notes.json`.
        **Blocked sentinels:** emit and return on `blocked:missing_aws_region`, `blocked:remote_runner_cloud2code_missing`, `blocked:remote_runner_awscli_missing`, `blocked:remote_runner_jq_missing`, `blocked:cloud2code_scan_failed`, `blocked:cloud2code_tfstate_missing`, or `blocked:cloud2code_tfstate_invalid`. Never fabricate an empty tfstate.

        The exact spawn/direct-fallback context follows. It is embedded here so
        the architect can execute the same bootstrap when subagent creation is
        unavailable instead of inventing a replacement command:

        ${local.aws_migrator_spawn_context_cloud2code}
      EOT
    },
    {
      stage_id         = "cloud2code-scan-loop"
      action_type      = "loop_stage"
      agent_ref        = ""
      stage_depends_on = ["cloud2code-scan-aws"]
      action_config = {
        loop_to        = "cloud2code-scan-aws"
        max_iterations = 5
        exit_condition = "output_matches_regex"
        # Only operator-fixable blockers end the loop. A transient platform
        # denial (e.g. identity lookup failing during a Guild rolling restart)
        # surfaces as missing_runner_evidence and must retry, so this regex
        # deliberately omits a stage_summary:...=blocked: catch-all.
        exit_match = "cloud2code_scan_ok[^\\n]{0,40}\"true\"|blocked:missing_aws_region|blocked:remote_runner_cloud2code_missing|blocked:remote_runner_awscli_missing|blocked:remote_runner_jq_missing|blocked:cloud2code_scan_failed|blocked:cloud2code_tfstate_missing|blocked:cloud2code_tfstate_invalid"
      }
    },
    {
      stage_id         = "scan-blocked-gate"
      action_type      = "conditional_skip"
      agent_ref        = ""
      stage_depends_on = ["cloud2code-scan-loop"]
      action_config = {
        condition = "output_matches_regex"
        # Require emitted sentinel forms (`: "true"` / stage_summary=blocked:), not bare
        # names — loop_stage FINISH reasons embed the exit_match pattern text and would
        # otherwise false-trigger this gate after a successful cloud2code_scan_ok.
        match   = "blocked:missing_aws_region:\\s*\\\"true\\\"|blocked:remote_runner_cloud2code_missing:\\s*\\\"true\\\"|blocked:remote_runner_awscli_missing:\\s*\\\"true\\\"|blocked:remote_runner_jq_missing:\\s*\\\"true\\\"|blocked:cloud2code_scan_failed:\\s*\\\"true\\\"|blocked:cloud2code_tfstate_missing:\\s*\\\"true\\\"|blocked:cloud2code_tfstate_invalid:\\s*\\\"true\\\"|stage_summary:cloud2code-scan-aws=blocked:"
        skip_to = "final-gate-and-memory"
        reason  = "Cloud2code scan blocked — skip ingest, registry, destination, and orphan stages"
      }
    },
    {
      stage_id         = "ingest-and-split"
      agent_ref        = sg_agent.aws_migrator_architect.name
      stage_depends_on = ["scan-blocked-gate"]
      runbook_refs = [
        sg_runbook_sop.aws_migrator_orchestration.name,
        sg_runbook_sop.tfstate_splitter.name,
      ]
      skill_refs = concat(
        [local.sop_orchestration_name, local.sop_tfstate_splitter_name],
        try(var.workflow_skill_refs["aws-cloud-discovery::ingest-and-split"], []),
        try(var.workflow_skill_refs["aws-cloud-discovery::ingest-monolith"], []),
      )
      note = <<-EOT
        DBSPLIT_ALLOCATE_SHA256=${local.script_pack_allocate_sha256}
        DBSPLIT_DECOMPOSER_SHA256=${local.script_pack_decomposer_sha256}
        Budget: ≤ 1 remote-runner script subagent, ≤ $1.50, ≤ 60m (script_runner_timeout_seconds=${local.subagent_budgets.script_runner_timeout_seconds}).
        **Incremental bring-up execution (mandatory):** this workspace runs stages in an execution mode that does not expose `create_agent`. Do **not** attempt `create_agent`, and never report this stage blocked because a subagent could not be spawned — run the runner work yourself with exactly **one** `${local.shell_tool_prefix}_execute_command` call, using the embedded ingest context below. Never author your own shell: `execute_command` runs under `/bin/sh` (dash), so `set -o pipefail` and nested single quotes in an LLM-composed command fail instantly (trace `28f93699`: 1 ms exit, no work performed).
        **Step 0 — consume cloud2code handoff:** call `read_notes` once for `cloud2code_tfstate_path`, `monolith_state_uri`, and `tfstate_file`, but do not block when platform notes are empty and do **not** pre-write `.work/spawn_monolith_uri` yourself. The bootstrap resolves `WORK_ROOT` from `WORKFLOW_RUN_ID` and `MONOLITH_URI` from `$HOME/.<workflow_run_id>/notes.json` (the authoritative disk mirror written by the scan bootstrap) on its own. **Do not ask the operator for `monolith_state_uri`**; this workflow creates it in `cloud2code-scan-aws`. When the bootstrap prints `blocked:missing_monolith_state_uri` (or `error=MONOLITH_URI_unset`), note that sentinel and return — never ask clarifying questions.
        **Runbook authority:** this stage MUST use the workspace runbook **`${local.sop_tfstate_splitter_name}`** for the tfstate decomposition step, implemented in the script pack as **`tfstate_monolith_decomposer.py`**. The runner MUST NOT single-pass the split: it must run the decomposer, scaffold registry artifacts so `orphans_bundle` exists, score `split_quality_report`, inspect `split_tuning_history`, and rerun with tuned `tfstate_decomposer_*` controls when the report recommends an optimization. Default objective: preserve count reconciliation first, then minimize `metrics.orphan_count`, then reduce high-impact review items and fragmentation.
        **Split quality floors:** clean pass requires `quality_score >= 80` with no hard issues; after bounded tuning the runner may soft-pass a best candidate at `quality_score >= 70` with no hard issues (`selection_reason=best_candidate_after_bounded_tuning`). Soft-pass is acceptable, not excellent — prefer improving grouping when practical.
        **INGEST FAIL signature (trace f23d78e0 / ffc0a822 / 019e9036 / ea8f5ab7 / 28f93699):** heredoc paste, **`create_files`** with giant script payloads, LLM-authored shell in `execute_command`, or **`execute_series`** JSON paste → shell syntax errors. Use **exactly one `execute_command` call:** paste **`INGEST_BOOTSTRAP_EXECUTE_COMMAND`** verbatim (raw preloaded bootstrap at `${local.script_pack_preload_dir}/ingest-bootstrap.sh`; large scripts are preloaded in the same directory) — **`timeout_seconds=${local.subagent_budgets.script_runner_timeout_seconds}`** (never 60). Never call `${local.resolved_github_integration_name}_*` or `${local.resolved_aws_integration_name}_*` MCP tools for this work (trace 019e905a51fc). Trace **8c7ea4ad:** bootstrap **< 60s** + missing handoff → **`MONOLITH_URI_unset`**.
        **INGEST RETRY (max 1 retry):** re-run the **same single `execute_command` call** — never create_files, heredoc, or an LLM-authored script body. Missing `script_pack_version` after bootstrap **< 120s** → wrong tool order or timeout too low. After **two failed attempts**, emit **`blocked:three_runner_attempts_failed: "true"`** and **`blocked:ingest_script_pack_failed: "true"`**; do **NOT** fall back to inline python splitters.
        **INGEST STOP RULE (mandatory after bootstrap success):** apply ONLY when `count_reconciliation_ok: "true"` AND `split_quality_pass: "true"` AND non-empty `split_quality_report` AND non-empty `logical_group_manifest_path`. Read handoff keys from **`$WORK_ROOT/notes.json`** or **`$WORK_ROOT/.work/ingest-handoff.txt`** — **NOT** from execute_command stdout (trace `88b0393c`: stdout truncated → empty keys). Then: (1) `note("stage_summary:ingest-and-split", "ok")` without overwriting handoff keys; (2) final message echoing reconcile and split-quality keys; (3) **RETURN immediately**.
        **Script pack (mandatory):** preloaded on the runner at **`${local.script_pack_preload_dir}`** with sha gates allocate=${local.script_pack_allocate_sha256}, decomposer=${local.script_pack_decomposer_sha256}, runner=${local.script_pack_runner_sha256}. The embedded context below delivers the short **`INGEST_BOOTSTRAP_EXECUTE_COMMAND`** — paste it into the single `execute_command`. See orchestration SOP § *Script pack*.
        **Success criteria:** final line MUST include `count_reconciliation_ok: "true"` or `"false"` (quoted), `split_quality_pass: "true"` or `"false"` (quoted), `split_quality_score=<N>`, `tfstate_decomposer_orphan_count=<N>`, `script_pack_version: "${local.script_pack_version}"`, and `script_pack_verify_ok: "true"` when reconcile succeeded. If `logical_group_count` is 1 and group id is `ungrouped` with `monolith_resource_count > 5000`, emit **`script_pack_drift_possible: "true"`** (non-blocking warning — likely non-canonical inline python recovery; do not treat as a terminal blocker).
        **Outputs:** `monolith_state_local_path`, `logical_group_manifest`, `group_state_paths`, `count_reconciliation_ok`, `logical_group_count`, `split_quality_report`, `split_tuning_history`, `split_tuning_iterations`, `tfstate_decomposer_orphan_count`, `review_items_path`, `layer_summary_path`, `script_pack_version`, DB anchor inventory paths. Echo group count + shared group ids in final message. Final line MUST include `count_reconciliation_ok: "true"` or `count_reconciliation_ok: "false"` and `split_quality_pass: "true"` or `split_quality_pass: "false"` (quoted strings).
        `note` `stage_summary:ingest-and-split` AND mirror all handoff keys to `$HOME/.<workflow_run_id>/notes.json`. Never `load_skill` / `submit_evidence` here.

        The exact ingest bootstrap follows. It is embedded here so this stage can
        run the single command itself when subagent creation is unavailable
        instead of inventing a replacement command:

        ${local.dbsplit_spawn_context_ingest}
      EOT
    },
    {
      stage_id         = "ingest-split-loop"
      action_type      = "loop_stage"
      agent_ref        = ""
      stage_depends_on = ["ingest-and-split"]
      action_config = {
        loop_to        = "ingest-and-split"
        max_iterations = var.max_convergence_iterations
        exit_condition = "output_matches_regex"
        # Same rule as the scan loop: no stage_summary:...=blocked: catch-all,
        # so a transient platform denial retries instead of ending the run.
        # script_pack_drift_possible is a warning only — omitted from exit_match.
        exit_match = "count_reconciliation_ok[^\\n]{0,40}\"true\"[\\s\\S]*split_quality_pass[^\\n]{0,40}\"true\"|split_quality_pass[^\\n]{0,40}\"true\"[\\s\\S]*count_reconciliation_ok[^\\n]{0,40}\"true\"|blocked:missing_monolith_state_uri|blocked:three_runner_attempts_failed|blocked:ingest_script_pack_failed|script_pack_verify_ok[^\\n]{0,40}\"false\"|script_pack_error="
      }
    },
    {
      stage_id         = "ingest-blocked-gate"
      action_type      = "conditional_skip"
      agent_ref        = ""
      stage_depends_on = ["ingest-split-loop"]
      action_config = {
        condition = "output_matches_regex"
        # Use emitted sentinel forms only. loop_stage FINISH reasons paste the
        # exit_match regex (e.g. script_pack_verify_ok[^\\n]{0,40}\"false\") and
        # must not trip this gate after a successful split.
        match   = "blocked:missing_monolith_state_uri:\\s*\\\"true\\\"|blocked:three_runner_attempts_failed:\\s*\\\"true\\\"|blocked:ingest_script_pack_failed:\\s*\\\"true\\\"|stage_summary:ingest-and-split=blocked:|script_pack_verify_ok:\\s*\\\"false\\\"|count_reconciliation_ok:\\s*\\\"false\\\"|split_quality_pass:\\s*\\\"false\\\"|script_pack_error=[A-Za-z0-9_]"
        skip_to = "final-gate-and-memory"
        reason  = "Ingest or split quality failure — skip registry, converge, destination, and orphan stages"
      }
    },
    {
      stage_id         = "registry-and-import-codegen"
      agent_ref        = sg_agent.aws_migrator_architect.name
      stage_depends_on = ["ingest-blocked-gate"]
      runbook_refs = [
        sg_runbook_sop.terraform_registry_reverse_iac.name,
        sg_runbook_sop.aws_migrator_orchestration.name,
      ]
      skill_refs = concat(
        [local.sop_orchestration_name, local.sop_registry_reverse_name],
        try(var.workflow_skill_refs["aws-cloud-discovery::registry-and-import-codegen"], [])
      )
      note = <<-EOT
        **Upstream blocked guard (step 0):** trip this guard **only** when the upstream output positively shows a failure — a cloud2code blocked sentinel, `blocked:missing_monolith_state_uri`, `blocked:three_runner_attempts_failed`, `blocked:ingest_script_pack_failed`, `count_reconciliation_ok` present and not `"true"`, `split_quality_pass` present and not `"true"`, or `stage_summary:ingest-and-split=blocked:`. A key that is simply **absent** is never a blocker: if `count_reconciliation_ok` and `split_quality_pass` both read `"true"`, proceed with the runner work even when no `stage_summary:ingest-and-split` line is present. When the guard does trip, emit one-line `notify({stage:'registry-and-import-codegen',error:'upstream_ingest_blocked'})` and **return** (no remediation prose).
        **Incremental bring-up execution (mandatory):** this workspace runs stages in an execution mode that does not expose `create_agent`. Do **not** attempt `create_agent`, and never report this stage blocked because a subagent could not be spawned — run the runner work yourself using the embedded context below. Never author your own scaffold or PR shell.
        **Script-first IaC PR (mandatory):** make **ONE** `${local.shell_tool_prefix}_execute_series` call that pastes IAC_PR_EXECUTE_SERIES verbatim. Pipeline: registry scaffold → prepare-parallel-artifacts → clone → cp sync groups → gh pr create.
        After it succeeds: `note()` stdout keys including `batch_payloads_path`, `pr_url`, `large_state_sample_group_ids`. Final message echoes `pr_url=` (may be empty on pr_blocker) and `stage_summary:registry-and-import-codegen`.
        **Hard evidence gate:** never report this stage complete from notes or reasoning alone. Completion requires a successful `${local.shell_tool_prefix}_execute_series` result carrying a non-empty `batch_payloads_path` plus either a `pr_url` or an explicit `pr_blocker` reason. Absent those, record `stage_summary:registry-and-import-codegen=blocked:missing_runner_evidence` and return blocked — a silent pass here starves `shell-converge-matrix` of the synced repo and shows up downstream as unexplained `fail_groups`.
        Forbidden: LLM-per-group scaffold, inline python, `create_files`, second execute_series, `*-probe`, `*-disk-mirror`.

        The exact IaC PR series follows. It is embedded here so this stage can
        run it itself when subagent creation is unavailable instead of
        inventing a replacement command:

        ${local.dbsplit_spawn_context_registry}
      EOT
    },
    {
      stage_id         = "shell-converge-matrix"
      agent_ref        = sg_agent.aws_migrator_architect.name
      stage_depends_on = ["registry-and-import-codegen"]
      runbook_refs = [
        sg_runbook_sop.terraform_registry_reverse_iac.name,
        sg_runbook_sop.terraform_substate_convergence.name,
        sg_runbook_sop.aws_migrator_orchestration.name,
      ]
      skill_refs = concat(
        [local.sop_orchestration_name, local.sop_registry_reverse_name, local.sop_substate_converge_name],
        try(var.workflow_skill_refs["aws-cloud-discovery::shell-converge-matrix"], []),
        try(var.workflow_skill_refs["aws-cloud-discovery::hcl-hydrate-per-group"], []),
      )
      note = <<-EOT
        **Upstream blocked guard (step 0):** trip only on a positively present ingest failure sentinel (`blocked:ingest_script_pack_failed`, `blocked:three_runner_attempts_failed`, or `count_reconciliation_ok` present and not `"true"`) → one-line `notify({stage:'shell-converge-matrix',error:'upstream_ingest_blocked'})` and **return**. A missing key is not a blocker; when the ingest counters read `"true"`, run the converge series.
        **Incremental bring-up execution (mandatory):** this workspace runs stages in an execution mode that does not expose `create_agent`. Do **not** attempt `create_agent`, and never report this stage blocked because a subagent could not be spawned — run the runner work yourself using the embedded context below.
        **One series, then return:** make **ONE** `${local.shell_tool_prefix}_execute_series` call pasting CONVERGE_EXECUTE_SERIES verbatim — it runs `hydrate-and-plan-matrix` over `sample_group_ids.json`, performing repaired `tofu init` (provider cache / TF data moved to runner scratch when needed), import-code hydration, `tofu fmt -check`, `tofu validate`, `tofu test` when tests exist, `tflint` when installed, and final `tofu plan` zero-change verification. Then **RETURN** — no probes, no re-runs.
        **Forbidden agent names:** `*-probe`, `*-disk-mirror`, `*-extract-*`, `*-v2`, `hcl-hydrate-runner-batch-*` (script owns hydration).
        After the series: parse stdout for `multi_plan_zero_diff_ok: "true"|"false"`, `hydrate_ok_groups=`, `hydrate_fail_groups=`, mirror `hcl_hydration_status:*` and `hcl_init_status:*` keys from notes/disk. If `multi_plan_zero_diff_ok` is `"false"`, do not mark a terminal blocker unless the output contains `blocked:remote_runner_tofu_missing`, `blocked:remote_runner_shell_unavailable`, or `stage_summary:shell-converge-matrix=blocked:`; let `shell-converge-loop` retry up to its cap. `note stage_summary:shell-converge-matrix`.

        The exact converge series follows. It is embedded here so this stage can
        run it itself when subagent creation is unavailable instead of
        inventing a replacement command:

        ${local.dbsplit_spawn_context_converge}
      EOT
    },
    {
      stage_id         = "shell-converge-loop"
      action_type      = "loop_stage"
      agent_ref        = ""
      stage_depends_on = ["shell-converge-matrix"]
      runbook_refs     = null
      skill_refs       = null
      action_config = {
        loop_to        = "shell-converge-matrix"
        max_iterations = var.max_convergence_iterations
        exit_condition = "output_matches_regex"
        exit_match     = "multi_plan_zero_diff_ok[^\\n]{0,40}\"true\"|blocked:remote_runner_tofu_missing|blocked:remote_runner_shell_unavailable|stage_summary:shell-converge-matrix=blocked:"
      }
      note = "Loop back to shell-converge-matrix until AWS Terraform validation converges to a zero-diff plan or a terminal runner/convergence blocker is recorded."
    },
    {
      stage_id         = "converge-blocked-gate"
      action_type      = "conditional_skip"
      agent_ref        = ""
      stage_depends_on = ["shell-converge-loop"]
      action_config = {
        condition = "output_matches_regex"
        # Emitted sentinel forms only — loop_stage FINISH reasons paste exit_match
        # (e.g. blocked:remote_runner_tofu_missing) and must not trip after success.
        match   = "blocked:remote_runner_tofu_missing:\\s*\\\"true\\\"|blocked:remote_runner_shell_unavailable:\\s*\\\"true\\\"|stage_summary:shell-converge-matrix=blocked:"
        skip_to = "final-gate-and-memory"
        reason  = "Shell converge blocked — skip orphan and final destination stages"
      }
    },
    {
      stage_id         = "orphans-secondary-pipeline"
      agent_ref        = sg_agent.aws_migrator_architect.name
      stage_depends_on = ["converge-blocked-gate"]
      runbook_refs = [
        sg_runbook_sop.aws_migrator_orchestration.name,
        sg_runbook_sop.orphan_iac_module_bootstrap.name,
      ]
      skill_refs = concat(
        [local.sop_orchestration_name, local.sop_orphan_bootstrap_name],
        try(var.workflow_skill_refs["aws-cloud-discovery::orphans-secondary-pipeline"], [])
      )
      note = <<-EOT
        **Max 2 tool turns:** `read_notes` (+ disk mirror fallback) → if upstream blocked sentinels are present → `note stage_summary:orphans-secondary-pipeline=skipped:upstream_blocked` and **return**. If `orphans_bundle` empty → `note stage_summary:orphans-secondary-pipeline=skipped:empty_orphans_bundle` and **return**. Else build `secondary_workflow_payload` and notify/start orphan workflow.
        **Forbidden:** `*-entry-probe`, `*-disk-mirror`, `*-bundle-snapshot` subagents.
      EOT
    },
    {
      stage_id         = "final-gate-and-memory"
      agent_ref        = sg_agent.aws_migrator_architect.name
      stage_depends_on = ["orphans-secondary-pipeline"]
      runbook_refs = [
        sg_runbook_sop.aws_migrator_orchestration.name,
        sg_runbook_sop.orphan_iac_module_bootstrap.name,
      ]
      skill_refs = concat(
        [local.sop_orchestration_name, local.sop_orphan_bootstrap_name],
        try(var.workflow_skill_refs["aws-cloud-discovery::final-gate-and-memory"], []),
        try(var.workflow_skill_refs["aws-migrator-discovery::final-gate-and-memory"], [])
      )
      note = <<-EOT
        **Blocked / early-skip guards (step 0):** if notes contain cloud2code/ingest/registry blocked summaries, terminal runner blockers, or gate-skip markers (`stage_summary:orphans-secondary-pipeline=skipped:upstream_blocked`, preflight/scan/ingest/converge blocked sentinels) → one `notify` with the terminal reason + `stage_summary:final-gate-and-memory=blocked:<reason>` and **return**.
        **Convergence guard (step 1):** only when no upstream terminal blocker: if `multi_plan_zero_diff_ok` is not `"true"` → `blocked:plan_not_converged`. Require a non-empty `pr_url` / `iac_pr_url` (multi-commit aws-cloud-discovery PR).
        **Evidence gate:** `submit_evidence` for aws-cloud-discovery checklist items.
        Final `notify` with discovery PR URL + per-group validation tables (or a single blocked rollup). Never emit owner "HCL AUTHOR".
        `note` `stage_summary:final-gate-and-memory` and mirror to `$HOME/.<workflow_run_id>/notes.json`.
        **Final message format (mandatory — operator/UI rollup):** Title **`## final-gate-and-memory — COMPLETE`** on success, or **`## final-gate-and-memory — BLOCKED`** when step 0 trips. Include **Evidence Gate** table, **Convergence Guards** table (when applicable), discovery PR URL, and **`stage_summary:final-gate-and-memory=ok|blocked:<reason>`**.
      EOT
    },
  ]
}

