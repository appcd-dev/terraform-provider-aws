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
        **Operator scan filters (mandatory):** when the query set `cloud2code_include`, `cloud2code_exclude`, or `cloud2code_tags`, copy each value into the matching `CLOUD2CODE_*=''` slot at the front of the one-liner before pasting it. That env prefix is the only path from the query to `cloud2code import aws`; leaving it empty scans the whole region regardless of what the operator asked for.
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
        **Incremental bring-up execution (mandatory):** `create_agent` is allowed (reactree). Put the exact command in CREATE_AGENT_EXPECTATION, or run it yourself with exactly **one** `${local.shell_tool_prefix}_execute_command` call, using the embedded ingest context below. Never author your own shell: `execute_command` runs under `/bin/sh` (dash), so `set -o pipefail` and nested single quotes in an LLM-composed command fail instantly (trace `28f93699`: 1 ms exit, no work performed).
        **Step 0 — consume cloud2code handoff:** call `read_notes` once for `cloud2code_tfstate_path`, `monolith_state_uri`, and `tfstate_file`, but do not block when platform notes are empty and do **not** pre-write `.work/spawn_monolith_uri` yourself. The bootstrap resolves `WORK_ROOT` from `WORKFLOW_RUN_ID` and `MONOLITH_URI` from `$HOME/.<workflow_run_id>/notes.json` (the authoritative disk mirror written by the scan bootstrap) on its own. **Do not ask the operator for `monolith_state_uri`**; this workflow creates it in `cloud2code-scan-aws`. When the bootstrap prints `blocked:missing_monolith_state_uri` (or `error=MONOLITH_URI_unset`), note that sentinel and return — never ask clarifying questions.
        **Required result:** every scanned resource must appear exactly once in a generated group, and each group must have a state file. The later stage must then generate readable `.tf` files and run Terraform checks. Missing split scoring or tuning reports are warnings, not blockers.
        **Optional readiness analysis:** when available, use `split_quality_report` and `split_tuning_history` to improve grouping and write plain-language suggestions. Do not retry or stop solely because either report is missing or its score is low. Continue with the best correct split and record `split_quality_status=available|not_available`.
        **INGEST FAIL signature (trace f23d78e0 / ffc0a822 / 019e9036 / ea8f5ab7 / 28f93699):** heredoc paste, **`create_files`** with giant script payloads, LLM-authored shell in `execute_command`, or **`execute_series`** JSON paste → shell syntax errors. Use **exactly one `execute_command` call:** paste **`INGEST_BOOTSTRAP_EXECUTE_COMMAND`** verbatim (raw preloaded bootstrap at `${local.script_pack_preload_dir}/ingest-bootstrap.sh`; large scripts are preloaded in the same directory) — **`timeout_seconds=${local.subagent_budgets.script_runner_timeout_seconds}`** (never 60). Never call `${local.resolved_github_integration_name}_*` or `${local.resolved_aws_integration_name}_*` MCP tools for this work (trace 019e905a51fc). Trace **8c7ea4ad:** bootstrap **< 60s** + missing handoff → **`MONOLITH_URI_unset`**.
        **INGEST RETRY (max 1 retry):** re-run the **same single `execute_command` call** — never create_files, heredoc, or an LLM-authored script body. Missing `script_pack_version` after bootstrap **< 120s** → wrong tool order or timeout too low. After **two failed attempts**, emit **`blocked:three_runner_attempts_failed: "true"`** and **`blocked:ingest_script_pack_failed: "true"`**; do **NOT** fall back to inline python splitters.
        **INGEST STOP RULE (mandatory after bootstrap success):** continue when `count_reconciliation_ok: "true"` and `logical_group_manifest_path` plus `group_state_paths` are non-empty. `split_quality_report`, `split_tuning_history`, and `split_quality_pass` are optional readiness signals. Read handoff keys from **`$WORK_ROOT/notes.json`** or **`$WORK_ROOT/.work/ingest-handoff.txt`** — **NOT** from execute_command stdout (trace `88b0393c`: stdout truncated → empty keys). Then: (1) `note("stage_summary:ingest-and-split", "ok")` without overwriting handoff keys; (2) report whether readiness analysis is available; (3) **RETURN immediately**.
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
        exit_match = "count_reconciliation_ok[^\\n]{0,40}\"true\"|blocked:missing_monolith_state_uri|blocked:three_runner_attempts_failed|blocked:ingest_script_pack_failed|script_pack_verify_ok[^\\n]{0,40}\"false\"|script_pack_error="
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
      runbook_refs = [
        sg_runbook_sop.terraform_registry_reverse_iac.name,
        sg_runbook_sop.aws_migrator_orchestration.name,
      ]
      skill_refs = concat(
        [local.sop_orchestration_name, local.sop_registry_reverse_name],
        try(var.workflow_skill_refs["aws-cloud-discovery::registry-and-import-codegen"], [])
      )
      note = <<-EOT
        **Upstream blocked guard (step 0):** stop only for a confirmed scan failure, a missing state file, a script-pack failure, or `count_reconciliation_ok` present and not `"true"`. Missing or low split-quality results are warnings. Continue when every scanned resource was assigned exactly once and group state files exist.
        **Incremental bring-up execution (mandatory):** `create_agent` is allowed (reactree). Put the exact BEGIN/END body in CREATE_AGENT_EXPECTATION, or paste it yourself using the embedded context below. Never author your own scaffold or PR shell.
        **Script-first IaC PR (mandatory):** make **ONE** `${local.shell_tool_prefix}_execute_series` call that pastes IAC_PR_EXECUTE_SERIES verbatim. Pipeline: registry scaffold → prepare-parallel-artifacts → clone → cp sync groups → gh pr create.
        After it succeeds: `note()` stdout keys including `batch_payloads_path`, `pr_url`, `large_state_sample_group_ids`. Final message echoes `pr_url=` (may be empty on pr_blocker) and `stage_summary:registry-and-import-codegen`.
        **Hard evidence gate:** never report this stage complete from notes or reasoning alone. Completion requires a successful `${local.shell_tool_prefix}_execute_series` result carrying a non-empty `batch_payloads_path` plus either a `pr_url` or an explicit `pr_blocker` reason. Absent those, record `stage_summary:registry-and-import-codegen=blocked:missing_runner_evidence` and return blocked — a silent pass here starves `shell-converge-matrix` of the synced repo and shows up downstream as unexplained `fail_groups`.
        Forbidden: LLM-per-group scaffold, inline python, `create_files`, second execute_series, `*-probe`, `*-disk-mirror`.

        The exact IaC PR series follows. Put this BEGIN/END body in CREATE_AGENT_EXPECTATION
        (or paste it yourself). Never invent a replacement command:

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
        **Incremental bring-up execution (mandatory):** `create_agent` is allowed (reactree). Put the exact BEGIN/END body in CREATE_AGENT_EXPECTATION, or paste it yourself using the embedded context below.
        **One series, then return:** make **ONE** `${local.shell_tool_prefix}_execute_series` call pasting CONVERGE_EXECUTE_SERIES verbatim — it runs `hydrate-and-plan-matrix` over `sample_group_ids.json`, performing repaired `tofu init` (provider cache / TF data moved to runner scratch when needed), import-code hydration, `tofu fmt -check`, `tofu validate`, `tofu test` when tests exist, `tflint` when installed, and final `tofu plan` zero-change verification. Then **RETURN** — no probes, no re-runs.
        **Forbidden agent names:** `*-probe`, `*-disk-mirror`, `*-extract-*`, `*-v2`, `hcl-hydrate-runner-batch-*` (script owns hydration).
        After the series: require `terraform_validation_ok: "true"`. Report `multi_plan_zero_diff_ok` separately as an optional stronger check. A valid generated configuration may continue even when the plan shows changes or could not run. Use `terraform_valid_groups`, `terraform_invalid_groups`, and `terraform_zero_change_groups` in plain-language output.

        The exact converge series follows. Put this BEGIN/END body in CREATE_AGENT_EXPECTATION
        (or paste it yourself). Never invent a replacement command:

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
        exit_match     = "terraform_validation_ok[^\\n]{0,40}\"true\"|blocked:remote_runner_tofu_missing|blocked:remote_runner_shell_unavailable|stage_summary:shell-converge-matrix=blocked:"
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
        **Required result:** report success when the scan completed, every scanned resource appears exactly once in the generated folders, readable `.tf` files exist, and Terraform format plus validation pass. A zero-change plan is the strongest result; if it could not run, report the exact checks that passed and what remains.
        **Optional readiness analysis:** missing `split_quality_report`, `split_tuning_history`, a low grouping score, or orphan suggestions must not change a successful Terraform result into a failure. Put these under "Ways to improve readiness."
        **Plain-language output:** avoid internal terms such as monolith, ingest, shard, hydration, convergence, decomposition, handoff, evidence gate, sentinel, DAG, or matrix. Say "scanned state," "Terraform folder," "generated file," "Terraform checks," and "readiness suggestion."
        Final `notify` must include the pull request URL, number of scanned resources, number of Terraform folders, checks that passed, checks that did not run, and up to five concrete readiness suggestions.
        `note` `stage_summary:final-gate-and-memory` and mirror to `$HOME/.<workflow_run_id>/notes.json`.
        **Final message format:** use `## Terraform ready` when required checks pass, `## Terraform needs work` when files exist but checks failed, or `## Could not generate Terraform` when no usable files exist. Use three short sections: "Result", "Checks", and "Ways to improve readiness". Keep internal note keys out of the operator message.
      EOT
    },
  ]
}

