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
    Prefer `${local.shell_tool_prefix}_execute_series` for multi-step shell work. When a check fails, keep using the runner to diagnose and fix it.
    **DAG:** `runner-capability-preflight` → `preflight-blocked-gate` → `cloud2code-scan-aws` → `cloud2code-scan-loop` → `scan-blocked-gate` → `ingest-and-split` → `ingest-split-loop` → `ingest-blocked-gate` → `registry-and-import-codegen` → `shell-converge-matrix` → `shell-converge-loop` → `converge-blocked-gate` → `orphans-secondary-pipeline` → `final-gate-and-memory`. Blocked gates jump to `final-gate-and-memory`.
  EOT
  approve     = true

  metadata = {
    planner_max_tool_iterations = 24
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

  # The orchestration SOP is deliberately absent. Stages already implement its
  # sequence, and a workflow-level binding makes every stage inherit it as a
  # prescriptive runbook, so each stage replays all 20 procedures instead of
  # doing its own work (session e287557d). It stays in per-stage skill_refs.
  runbook_refs = [
    sg_runbook_sop.cloud2code_aws_region_scan.name,
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
        note        = "loop_stage only — no LLM. Exit on cloud2code_scan_ok=true or hard missing-tool/region blockers. Import failures stay in-loop so the agent can read the log and retry."
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
        description = "Organize the scanned resources into Terraform folders without losing or duplicating anything"
        note        = "A correct split is required. The readiness score and tuning history are optional suggestions."
        required    = true
      },
      {
        stage_id    = "ingest-split-loop"
        description = "Retry only when scanned resources are missing or duplicated"
        note        = "Exit when every scanned resource appears exactly once. Readiness reports are optional."
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
        description = "Generate readable Terraform files and prepare the pull request"
        note        = "Creates the Terraform folders and pull request. Terraform checks run next."
        required    = true
      },
      {
        stage_id    = "shell-converge-matrix"
        description = "Format and validate the generated Terraform, then check that it matches AWS"
        note        = "The generated .tf files must pass Terraform format and validation. Report remaining changes in plain language."
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
        description = "Report the Terraform result and what would improve its readiness"
        note        = "Lead with the pull request and validation result. Put optional improvements after the result."
        required    = true
      },
    ],
  )

  stage_bindings = [
    {
      stage_id  = "runner-capability-preflight"
      agent_ref = sg_agent.aws_migrator_architect.name
      # Stage sequencing already implements the orchestration SOP. Binding it as
      # a prescriptive runbook makes Guild execute all 20 SOP steps in this stage.
      runbook_refs = null
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
      # Keep SOPs as skills below. Prescriptive runbook bindings execute the
      # whole document and bypass this stage's bounded scan contract.
      runbook_refs = null
      skill_refs = concat(
        [local.sop_cloud2code_scan_name, local.sop_orchestration_name],
        try(var.workflow_skill_refs["aws-cloud-discovery::cloud2code-scan-aws"], []),
      )
      note = <<-EOT
        **Purpose:** create the monolithic AWS Terraform state for this workflow. This stage owns `monolith_state_uri`; downstream stages must not ask the operator for it.
        **Incremental bring-up execution:** `create_agent` is allowed (reactree). Spawn ONE `cloud2code-scan-runner` with CREATE_AGENT_EXPECTATION from the spawn context. `tool_names` only `["${local.shell_tool_prefix}_execute_series"]`.
        **Paste rule (mandatory):** `commands[0].command` MUST be exactly the BEGIN/END `CLOUD2CODE_SCAN_EXECUTE_SERIES` body (starts with `CLOUD2CODE_INCLUDE=` and contains `bash -c` + `cloud2code-aws-scan.sh`). That script runs `cloud2code import aws` — there is no `cloud2code aws` subcommand. Do not rewrite it into env-only invocations or append `&&`.
        **FORBIDDEN (session 6dac05f9 / 32e2ad9f / 127f2c35 / af38cc9e):** inventing `set -euo pipefail` wrappers, `cloud2code aws`, `cloud2code aws discover`, `cloud2code aws scan`, custom SCAN_LOG/STATE_OUT shells, dropping `bash -c`, or calling `cloud2code-aws-scan.sh` with no args / trailing `&&`. Those fail with `Error: unknown command "aws"` or `blocked:missing_aws_region` and produce no tfstate.
        **Substitute before paste (mandatory):** replace `AWS_REGION_PLACEHOLDER` with the region AND replace `{{workflow_run_id}}` with the real id from the stagerunner `[Workflow execution]` header (e.g. `wf-aws-cloud-discovery-…`). Do **not** leave the brace token literal — Guild often does not expand it inside agent-pasted `execute_series` (session b2177674 wrote `/home/runner/.{{workflow_run_id}}/` and then could not self-diagnose).
        **Operator scan filters (mandatory):** when the query set `cloud2code_include`, `cloud2code_exclude`, or `cloud2code_tags`, copy each value into the matching `CLOUD2CODE_*=''` slot at the front of the one-liner before pasting it. That env prefix is the only path from the query to `cloud2code import aws`; leaving it empty scans the whole region regardless of what the operator asked for.
        **Self-heal on failure (mandatory):** if the runner returns `blocked:cloud2code_scan_failed`, `blocked:cloud2code_workflow_run_id_unresolved`, a missing tfstate sentinel, **or** `unknown command "aws" for "cloud2code"`, do **not** stop and do **not** invent another wrapper. Discard the bad command, paste the pack one-liner again (only substitution: real workflow_run_id + region + operator filters), and re-run:
        - `unknown command "aws"` / invented `cloud2code aws*` → you ignored the pack one-liner; paste BEGIN/END body only and retry
        - literal `{{workflow_run_id}}` / unresolved id → paste the real id and retry
        - outdated / missing `cloud2code` → rely on pack `ensure_cloud2code` (pin 0.5.2+) and retry
        - unsupported `--exclude` / filter errors → drop bad types from `CLOUD2CODE_EXCLUDE` or narrow `CLOUD2CODE_INCLUDE` and retry
        - transient AWS / runner blips → retry the same pack one-liner once
        Only emit a terminal `blocked:cloud2code_scan_failed: "true"` after at least one remediation attempt that used the pack one-liner (or when the log shows a clearly non-retryable cause such as missing AWS credentials with no alternate path). Never fabricate an empty tfstate.
        **Hard evidence gate:** never report this stage complete from notes or reasoning alone. Completion requires a successful `${local.shell_tool_prefix}_execute_series` result containing `cloud2code_scan_ok: "true"`, a non-empty `monolith_state_uri`, and `monolith_resource_count` greater than zero. If those values are absent after remediation, record `stage_summary:cloud2code-scan-aws=blocked:missing_runner_evidence` (retryable) rather than inventing success. Do **not** invent custom summaries like `blocked — scan command invalid` — that skips the scan loop without healing.
        **Success criteria:** final line must include `cloud2code_scan_ok: "true"`, `cloud2code_tfstate_path=...`, `monolith_state_uri=...`, and `monolith_resource_count=<N>`. Also `note` those keys and mirror them to `$HOME/.<workflow_run_id>/notes.json`.

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
        # Exit only on success or hard missing-tool / missing-region blockers.
        # Import failures (`blocked:cloud2code_scan_failed`) are retryable: the
        # agent must read the log tail, remediate, and re-run (session b2177674
        # exited the loop on the first failure without healing).
        # Runner output uses cloud2code_scan_ok=true while agent summaries may
        # quote the value. Matching the true token accepts both forms.
        exit_match = "cloud2code_scan_ok[^\\n]{0,40}true|blocked:missing_aws_region|blocked:remote_runner_cloud2code_missing|blocked:remote_runner_awscli_missing|blocked:remote_runner_jq_missing"
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
        match   = "blocked:missing_aws_region:\\s*\\\"true\\\"|blocked:remote_runner_cloud2code_missing:\\s*\\\"true\\\"|blocked:remote_runner_awscli_missing:\\s*\\\"true\\\"|blocked:remote_runner_jq_missing:\\s*\\\"true\\\"|blocked:cloud2code_scan_failed:\\s*\\\"true\\\"|blocked:cloud2code_tfstate_missing:\\s*\\\"true\\\"|blocked:cloud2code_tfstate_invalid:\\s*\\\"true\\\"|blocked:cloud2code_workflow_run_id_unresolved:\\s*\\\"true\\\"|stage_summary:cloud2code-scan-aws=blocked:"
        skip_to = "final-gate-and-memory"
        reason  = "Cloud2code scan blocked — skip ingest, registry, destination, and orphan stages"
      }
    },
    {
      stage_id         = "ingest-and-split"
      agent_ref        = sg_agent.aws_migrator_architect.name
      stage_depends_on = ["scan-blocked-gate"]
      # The stage note owns the exact ingest bootstrap. A prescriptive runbook
      # can replace it with hand-written decomposition commands and wrong paths.
      runbook_refs = null
      skill_refs = concat(
        [local.sop_orchestration_name, local.sop_tfstate_splitter_name],
        try(var.workflow_skill_refs["aws-cloud-discovery::ingest-and-split"], []),
        try(var.workflow_skill_refs["aws-cloud-discovery::ingest-monolith"], []),
      )
      note = <<-EOT
        DBSPLIT_ALLOCATE_SHA256=${local.script_pack_allocate_sha256}
        DBSPLIT_DECOMPOSER_SHA256=${local.script_pack_decomposer_sha256}
        Budget: ≤ 1 remote-runner script subagent, ≤ $1.50, ≤ 60m (script_runner_timeout_seconds=${local.subagent_budgets.script_runner_timeout_seconds}).
        **Incremental bring-up execution (mandatory):** `create_agent` is allowed (reactree). Put the exact command in CREATE_AGENT_EXPECTATION, or run it yourself with exactly **one** `${local.shell_tool_prefix}_execute_command` call, using the embedded ingest context below. Never author your own shell: `execute_command` runs under `/bin/sh` (dash), so `set -o pipefail` and nested single quotes in an LLM-composed command fail instantly (trace `28f93699`: 1 ms exit, no work performed).
        **Step 0 — consume cloud2code handoff:** call `read_notes` once for `cloud2code_tfstate_path`, `monolith_state_uri`, and `tfstate_file`, but do not block when platform notes are empty and do **not** pre-write `.work/spawn_monolith_uri` yourself. The bootstrap resolves `WORK_ROOT` from `WORKFLOW_RUN_ID` and `MONOLITH_URI` from `$HOME/.<workflow_run_id>/notes.json` (the authoritative disk mirror written by the scan bootstrap) on its own. **Do not ask the operator for `monolith_state_uri`**; this workflow creates it in `cloud2code-scan-aws`. When the bootstrap prints `blocked:missing_monolith_state_uri` (or `error=MONOLITH_URI_unset`), note that sentinel and return — never ask clarifying questions.
        **Required result:** every scanned resource must appear exactly once in a generated group, and each group must have a state file. The later stage must then generate readable `.tf` files and run Terraform checks. Missing split scoring or tuning reports are warnings, not blockers.
        **Optional readiness analysis:** when available, use `split_quality_report` and `split_tuning_history` to improve grouping and write plain-language suggestions. Do not retry or stop solely because either report is missing or its score is low. Continue with the best correct split and record `split_quality_status=available|not_available`.
        **INGEST FAIL signature (trace f23d78e0 / ffc0a822 / 019e9036 / ea8f5ab7 / 28f93699):** heredoc paste, **`create_files`** with giant script payloads, LLM-authored shell in `execute_command`, or **`execute_series`** JSON paste → shell syntax errors. Use **exactly one `execute_command` call:** paste **`INGEST_BOOTSTRAP_EXECUTE_COMMAND`** verbatim (raw preloaded bootstrap at `${local.script_pack_preload_dir}/ingest-bootstrap.sh`; large scripts are preloaded in the same directory) — **`timeout_seconds=${local.subagent_budgets.script_runner_timeout_seconds}`** (never 60). Never call `${local.resolved_github_integration_name}_*` or `${local.resolved_aws_integration_name}_*` MCP tools for this work (trace 019e905a51fc). Trace **8c7ea4ad:** bootstrap **< 60s** + missing handoff → **`MONOLITH_URI_unset`**.
        **INGEST RETRY (max 1 retry):** re-run the **same single `execute_command` call** — never create_files, heredoc, or an LLM-authored script body. Missing `script_pack_version` after bootstrap **< 120s** → wrong tool order or timeout too low. After **two failed attempts**, emit **`blocked:three_runner_attempts_failed: "true"`** and **`blocked:ingest_script_pack_failed: "true"`**; do **NOT** fall back to inline python splitters.
        **INGEST STOP RULE:** when `count_reconciliation_ok: "true"` and group paths are non-empty, `note("stage_summary:ingest-and-split", "ok")` (keep handoff keys) and finish the stage. Read handoff from `$WORK_ROOT/notes.json` or `$WORK_ROOT/.work/ingest-handoff.txt`, not truncated stdout.
        **Script pack (mandatory):** preloaded on the runner at **`${local.script_pack_preload_dir}`** with sha gates allocate=${local.script_pack_allocate_sha256}, decomposer=${local.script_pack_decomposer_sha256}, runner=${local.script_pack_runner_sha256}. The embedded context below delivers the short **`INGEST_BOOTSTRAP_EXECUTE_COMMAND`** — paste it into the single `execute_command`. See orchestration SOP § *Script pack*.
        **Success criteria:** final line MUST include `count_reconciliation_ok: "true"`, non-empty `logical_group_manifest_path` and `group_state_paths`, `split_quality_status=available|not_available`, `script_pack_version: "${local.script_pack_version}"`, and `script_pack_verify_ok: "true"`. If readiness analysis exists, also include its score and suggestions. If it does not, say "Readiness analysis was not generated; Terraform validation will still run."
        **Outputs:** required: `monolith_state_local_path`, `logical_group_manifest`, `group_state_paths`, `count_reconciliation_ok`, `logical_group_count`, and `script_pack_version`. Optional: `split_quality_report`, `split_tuning_history`, `split_tuning_iterations`, `tfstate_decomposer_orphan_count`, `review_items_path`, and `layer_summary_path`. Use plain language in the final message.
        `note` `stage_summary:ingest-and-split` AND mirror all handoff keys to `$HOME/.<workflow_run_id>/notes.json`. Never `load_skill` / `submit_evidence` here.

        The exact ingest bootstrap follows. Put it in CREATE_AGENT_EXPECTATION
        (or run the single command yourself). Never invent a replacement command:

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
        # Readiness reports are optional. A correct split exits the loop.
        exit_match = "count_reconciliation_ok[^\\n]{0,40}true|blocked:missing_monolith_state_uri|blocked:three_runner_attempts_failed|blocked:ingest_script_pack_failed|script_pack_verify_ok[^\\n]{0,40}false|script_pack_error="
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
        match   = "blocked:missing_monolith_state_uri:\\s*\\\"true\\\"|blocked:three_runner_attempts_failed:\\s*\\\"true\\\"|blocked:ingest_script_pack_failed:\\s*\\\"true\\\"|stage_summary:ingest-and-split=blocked:|script_pack_verify_ok:\\s*\\\"false\\\"|count_reconciliation_ok:\\s*\\\"false\\\"|script_pack_error=[A-Za-z0-9_]"
        skip_to = "final-gate-and-memory"
        reason  = "The scanned resources could not be split correctly, so Terraform generation cannot continue"
      }
    },
    {
      stage_id         = "registry-and-import-codegen"
      agent_ref        = sg_agent.aws_migrator_architect.name
      stage_depends_on = ["ingest-blocked-gate"]
      runbook_refs     = null
      skill_refs = concat(
        [local.sop_orchestration_name, local.sop_registry_reverse_name],
        try(var.workflow_skill_refs["aws-cloud-discovery::registry-and-import-codegen"], [])
      )
      note = <<-EOT
        Stop only for a confirmed scan/ingest failure (`count_reconciliation_ok` present and not `"true"`, missing state, script-pack failure). Soft split-quality scores are warnings.
        Goal: AWS group Terraform on a branch, plus `pr_url` or a concrete `pr_blocker`.
        **Must paste IAC_PR_EXECUTE_SERIES** below (pack: scaffold → artifacts → clone → sync → `gh pr create`). Do not hand-roll `git clone` / `gh pr create`. `create_agent` is fine.
        If clone fails with `could not read Username for 'https://github.com'`: the runner has SCM vault key `token`, not `GIT_TOKEN`. Re-run IAC_PR (it aliases `token`) or `export GIT_TOKEN="$token" GH_TOKEN="$token"` and retry — that is not a terminal `pr_blocker`.
        If clone/PR/fmt fails: read the runner output and keep fixing on the runner until `batch_payloads_path` exists and you have `pr_url` or a real `pr_blocker`. Prefer notes/inputs (`iac_repository_url`, `default_branch`) over asking the operator.
        Then `note()` `batch_payloads_path`, `pr_url`/`pr_blocker`, `large_state_sample_group_ids`, `stage_summary:registry-and-import-codegen`.

        ${local.dbsplit_spawn_context_registry}
      EOT
    },
    {
      stage_id         = "shell-converge-matrix"
      agent_ref        = sg_agent.aws_migrator_architect.name
      stage_depends_on = ["registry-and-import-codegen"]
      runbook_refs     = null
      skill_refs = concat(
        [local.sop_orchestration_name, local.sop_registry_reverse_name, local.sop_substate_converge_name],
        try(var.workflow_skill_refs["aws-cloud-discovery::shell-converge-matrix"], []),
        try(var.workflow_skill_refs["aws-cloud-discovery::hcl-hydrate-per-group"], []),
      )
      note = <<-EOT
        Stop only if ingest already recorded a failure sentinel. Missing keys are not blockers.
        Goal: `terraform_validation_ok: "true"` on sampled groups. Zero-change plan is optional.
        Start with CONVERGE_EXECUTE_SERIES below (hydrate → fmt → validate → optional test/lint/plan). `create_agent` is fine.
        If `tofu fmt -check` or validate fails: fix the HCL on the runner and re-check until validation passes or you hit a real runner blocker (`blocked:remote_runner_tofu_missing`, etc.).
        Then `note()` `terraform_validation_ok`, group lists, and `stage_summary:shell-converge-matrix`.

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
        # Runner output writes terraform_validation_ok=true unquoted while agent
        # summaries quote it. Requiring the quoted form kept a converged stage
        # looping until the visit cap (session e287557d).
        exit_match = "terraform_validation_ok[^\\n]{0,40}true|blocked:remote_runner_tofu_missing|blocked:remote_runner_shell_unavailable|stage_summary:shell-converge-matrix=blocked:"
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
      runbook_refs     = null
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
      runbook_refs     = null
      skill_refs = concat(
        [local.sop_orchestration_name, local.sop_orphan_bootstrap_name],
        try(var.workflow_skill_refs["aws-cloud-discovery::final-gate-and-memory"], []),
        try(var.workflow_skill_refs["aws-migrator-discovery::final-gate-and-memory"], [])
      )
      note = <<-EOT
        This workflow is AWS discovery only. Azure/GCP PRs are separate workflows — do not treat missing Azure/GCP evidence as a failure here.
        Success: scan done, every resource in exactly one folder, readable `.tf` files, fmt+validate pass, and a PR URL (or a concrete PR blocker already noted upstream).
        Zero-change plan and split-quality reports are optional. Say what passed, what did not run, and up to five readiness suggestions.
        `note` `stage_summary:final-gate-and-memory`. Operator message: `## Terraform ready` / `## Terraform needs work` / `## Could not generate Terraform` with Result, Checks, Ways to improve readiness.
      EOT
    },
  ]
}

