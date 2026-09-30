# =============================================================================
# Primary workflow — AWS region scan → decomposed TF states + plan convergence
# =============================================================================

resource "sg_workflow" "aws_migrator_discovery" {
  name        = local.workflow_primary_name
  domain      = "infrastructure-as-code"
  description = <<-EOT
    AWS cloud discovery. Runs cloud2code against one AWS region, splits the synthesized
    Terraform state into logical groups, reverse-engineers HCL, validates with tofu fmt
    and tofu validate, then opens one multi-commit discovery PR on discovery/<workflow_run_id>.
    A zero-change plan is preferred but optional. Destination Azure/GCP PRs are separate
    workflows (azure-migration-pr / gcp-migration-pr). Scratch paths use $HOME/.<workflow_run_id>/.
    **DAG:** runner-capability-preflight → preflight-blocked-gate → cloud2code-scan-aws →
    cloud2code-scan-loop → scan-blocked-gate → ingest-and-split → ingest-split-loop →
    ingest-blocked-gate → registry-and-import-codegen → shell-converge-matrix →
    shell-converge-loop → converge-blocked-gate → orphans-secondary-pipeline → final-gate-and-memory.
    Blocked gates jump to final-gate-and-memory.
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
    "cloud2code_allow_partial",
    "cloud2code_min_coverage_percent",
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
    "Scan AWS us-east-1 with cloud2code, split the generated tfstate into app projects, reverse HCL for every group, and treat fmt/validate as soft readiness (needs work), not a workflow abort",
    "Run cloud2code for us-west-2 (IAM excluded by default), then decompose by tag-seeded connectivity and open a PR with grouped Terraform roots",
    "Scan AWS us-east-1 resources tagged Environment:Production, split the synthesized state into smaller project states, and verify zero-diff plans",
    "Full-region AWS inventory: grouping_strategy=tfstate_monolith_decomposer, max_resources_per_appstack=120, tfstate_decomposer_env_scope=l2l3",
  ]

  triggers = [
    { field = "intent", values = ["aws-cloud-discovery", "aws-cloud2code-discovery", "cloud2code-aws-scan", "aws-region-to-terraform", "aws-brownfield-iac-discovery"], type = "passive" },
  ]

  # Explicit generic contract bypasses smart-runbook discovery (Unleash
  # aios.guild.smart_runbook.discovery.enabled). Empty refs auto-match
  # cloud2code-aws-region-scan-sop and DecomposeExecute it inside preflight.
  runbook_refs = [sg_runbook_sop.discovery_stage_contract.name]

  stages = concat(
    [
      {
        stage_id    = "runner-capability-preflight"
        description = "Verify remote-runner tools and script-pack preload before scan"
        note        = "Paste the preflight one-liner. Emits runner_capability_preflight_ok or blocked:remote_runner_*."
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
        note        = "Paste the scan one-liner. Writes monolith_state_uri for ingest-and-split."
        required    = true
      },
      {
        stage_id    = "cloud2code-scan-loop"
        description = "Retry cloud2code scan until a valid tfstate handoff or terminal blocked sentinel is emitted"
        note        = "loop_stage only — no LLM."
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
        note        = "Paste the ingest bootstrap. A correct split is required; readiness scores are optional."
        required    = true
      },
      {
        stage_id    = "ingest-split-loop"
        description = "Retry only when scanned resources are missing or duplicated"
        note        = "loop_stage only — no LLM."
        required    = false
      },
      {
        stage_id    = "ingest-blocked-gate"
        description = "Skip to final gate when ingest/split ended on a terminal blocked or reconcile failure"
        note        = "conditional_skip only — no LLM."
        required    = false
      },
      {
        stage_id    = "registry-and-import-codegen"
        description = "Generate readable Terraform files and prepare the pull request"
        note        = "Paste IAC_PR_EXECUTE_SERIES. Creates Terraform folders and a PR."
        required    = true
      },
      {
        stage_id    = "shell-converge-matrix"
        description = "Hydrate generated.tf, push to the PR, and improve fmt/validate"
        note        = "Paste CONVERGE_EXECUTE_SERIES. Always sync hydrate to the PR. Validation green is the loop goal; false must not skip sync or later stages."
        required    = true
      },
      {
        stage_id    = "shell-converge-loop"
        description = "Retry only when the validation sentinel is missing/truncated; exit on quoted true|false"
        note        = "loop_stage only — no LLM. Exit on terraform_validation_ok quoted true|false or a terminal runner blocker. Do not exit on sync alone."
        required    = false
      },
      {
        stage_id    = "converge-blocked-gate"
        description = "Skip to final gate only when shell converge hit a terminal runner blocker"
        note        = "conditional_skip only — no LLM. Validation false is not a skip."
        required    = false
      },
      {
        stage_id    = "orphans-secondary-pipeline"
        description = "Parallel layer: trigger orphan-iac-module-authoring when orphans_bundle non-empty"
        note        = "Skip when orphans_bundle empty. Max 2 tool turns."
        required    = false
      },
      {
        stage_id    = "final-gate-and-memory"
        description = "Report the Terraform result and what would improve its readiness"
        note        = "Lead with the PR and validation result. Optional improvements after."
        required    = true
      },
    ],
  )

  stage_bindings = [
    {
      stage_id     = "runner-capability-preflight"
      agent_ref    = sg_agent.aws_migrator_architect.name
      runbook_refs = [sg_runbook_sop.discovery_stage_contract.name]
      skill_refs   = try(var.workflow_skill_refs["aws-cloud-discovery::runner-capability-preflight"], [])
      note         = <<-EOT
        Goal: confirm the remote runner has the tools and script pack this workflow needs.
        Done when: your stage result includes the runner lines `runner_capability_preflight_ok: "true"` and `script_pack_ready: "true"` (or `script_pack_fetch=ok` / `script_pack_preload_dir=/opt/aws-migrator/script-pack/…` from a real pack fetch).
        How: ONE `${local.shell_tool_prefix}_execute_series` pasting the **exact** BEGIN/END `RUNNER_CAPABILITY_PREFLIGHT_EXECUTE_SERIES` body (starts with `GIT_TOKEN=` and `gh release download` of `pack-entry.sh`, ends with `preflight '{{workflow_run_id}}'`). create_agent is fine with that same body.
        **FORBIDDEN:** `printf` / `echo` of BEGIN/END markers; inventing `runner_capability_preflight_ok=true`; inventing `script_pack_dir_missing` / `fetch-script-pack.sh` / `runner_capability_preflight_blocked` checks; using the marker label as the command. Only the BEGIN/END body fetches the pack. Prefer working_dir omit or `/`.
        Prefer the pack command over inventing shell. Echo the runner success or blocker lines in your result; do not paraphrase them away.

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
        # Emitted sentinel forms only (same class as ingest/converge gates).
        # missing_runner_evidence omitted: worker mishandled the call, not a missing tool.
        match   = "blocked:remote_runner_jq_missing:\\s*\\\"true\\\"|blocked:remote_runner_awscli_missing:\\s*\\\"true\\\"|blocked:remote_runner_python3_missing:\\s*\\\"true\\\"|blocked:remote_runner_git_missing:\\s*\\\"true\\\"|blocked:remote_runner_tofu_missing:\\s*\\\"true\\\"|blocked:remote_runner_opa_missing:\\s*\\\"true\\\"|blocked:remote_runner_cloud2code_missing:\\s*\\\"true\\\"|blocked:remote_runner_script_pack_missing:\\s*\\\"true\\\"|blocked:remote_runner_shell_unavailable:\\s*\\\"true\\\""
        skip_to = "final-gate-and-memory"
        reason  = "Runner capability preflight failed — skip scan, ingest, destination, and orphan stages"
      }
    },
    {
      stage_id         = "cloud2code-scan-aws"
      stage_depends_on = ["preflight-blocked-gate"]
      agent_ref        = sg_agent.aws_migrator_architect.name
      runbook_refs     = [sg_runbook_sop.discovery_stage_contract.name]
      skill_refs       = []
      note             = <<-EOT
        Goal: scan the AWS region into Terraform state so later stages have a state file path. Do not ask the operator for that path.
        By default, permission-denied reads use Cloud2Code `--allow-partial`; continue ingest/split from usable state and retain scan output, integrity counters, and denied action examples (e.g. `iam:GetRolePolicy`) in the handoff. Additionally, continue from a validated partial state when Cloud2Code exits nonzero specifically with `could not import from aws: scan incomplete`, `read_failed>0`, no throttled types, and imported/listed coverage is at least `cloud2code_min_coverage_percent` (default 90). Persist the partial marker and counters in the PR. Set `cloud2code_allow_partial=false` for strict scans. Missing/invalid state, low coverage, throttling, and other errors remain blocking.
        Done when: the stage result includes `cloud2code_scan_ok: "true"`, a non-empty state path, and a positive resource count; include Cloud2Code scan output when emitted. The PR includes the scan report and source artifacts.
        How: Prefer the pack command: use the exact one-line body between `---BEGIN CLOUD2CODE_SCAN_EXECUTE_SERIES---` and `---END---` below in ONE `${local.shell_tool_prefix}_execute_series`, setting `commands[0].command` to that body. It starts with `GIT_TOKEN=` / `gh release download` of `pack-entry.sh`, then `scan`. create_agent is fine with that same body.
        **FORBIDDEN:** `command="CLOUD2CODE_SCAN_EXECUTE_SERIES"` or any other use of the marker label as the shell command (exit 127). Swap only `AWS_REGION_PLACEHOLDER` and `{{workflow_run_id}}`. Do not invent pack-dir checks or alternate cloud2code invocations.
        On mangled paste or exit 127, retry the same BEGIN/END body once. Echo the runner success/blocker lines; do not paraphrase. A validated partial read-failure scan may proceed only if the wrapper emits `cloud2code_scan_ok: "true"`, partial-acceptance evidence, and echoes the runner success/blocker lines without paraphrasing. Missing/invalid state, low coverage, throttling, or other errors remain blocked.

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
        # Require scan_ok AND tfstate_path so "No `cloud2code_scan_ok: \"true\"`"
        # prose cannot FINISH (session b506b854). Blocker names stay bare.
        exit_match = "cloud2code_scan_ok:\\s*\\\"true\\\"[\\s\\S]{0,400}cloud2code_tfstate_path=|blocked:missing_aws_region|blocked:remote_runner_cloud2code_missing|blocked:remote_runner_awscli_missing|blocked:remote_runner_jq_missing|blocked:cloud2code_scan_failed|blocked:cloud2code_partial_scan|blocked:cloud2code_state_empty|blocked:remote_runner_cloud2code_version_unavailable|script_pack_error="
      }
    },
    {
      stage_id         = "scan-blocked-gate"
      action_type      = "conditional_skip"
      agent_ref        = ""
      stage_depends_on = ["cloud2code-scan-loop"]
      action_config = {
        condition = "output_matches_regex"
        # Emitted sentinel forms only — must not be a bare substring of exit_match
        # (loop FINISH reasons paste exit_match text).
        match   = "blocked:missing_aws_region:\\s*\\\"true\\\"|blocked:remote_runner_cloud2code_missing:\\s*\\\"true\\\"|blocked:remote_runner_awscli_missing:\\s*\\\"true\\\"|blocked:remote_runner_jq_missing:\\s*\\\"true\\\"|blocked:cloud2code_scan_failed:\\s*\\\"true\\\"|blocked:cloud2code_partial_scan:\\s*\\\"true\\\"|blocked:cloud2code_state_empty:\\s*\\\"true\\\"|blocked:remote_runner_cloud2code_version_unavailable:\\s*\\\"true\\\"|blocked:cloud2code_tfstate_missing:\\s*\\\"true\\\"|blocked:cloud2code_tfstate_invalid:\\s*\\\"true\\\"|blocked:cloud2code_workflow_run_id_unresolved:\\s*\\\"true\\\"|stage_summary:cloud2code-scan-aws=blocked:|CLOUD2CODE_SCAN_EXECUTE_SERIES: not found|cloud2code-aws-scan\\.sh: No such file|script_pack_error=[A-Za-z0-9_]"
        skip_to = "final-gate-and-memory"
        reason  = "Cloud2code scan blocked — skip ingest, registry, destination, and orphan stages"
      }
    },
    {
      stage_id         = "ingest-and-split"
      agent_ref        = sg_agent.aws_migrator_architect.name
      stage_depends_on = ["scan-blocked-gate"]
      runbook_refs     = [sg_runbook_sop.discovery_stage_contract.name]
      skill_refs       = []
      note             = <<-EOT
        Goal: put every scanned resource into exactly one group folder, each with its own state file. Split-quality scores are optional.
        Done when: runner lines include `count_reconciliation_ok: "true"`, group paths, and `script_pack_verify_ok: "true"`.
        How: prefer the BEGIN/END pack command in this note (one `${local.shell_tool_prefix}_execute_command`, working_dir `/`, full timeout). create_agent is fine with the same body. Do not ask the operator for the state path; do not invent shell; do not use GitHub or AWS MCP tools for this stage.
        On `lock_error=timeout` / `blocked:split_lock_timeout`: re-run the same pack body once (dead holders are reclaimed). Do not write `count_reconciliation_ok=true` inside a "not produced" sentence. Echo runner lines; do not paraphrase them away.

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
        # Quoted true only — prose "count_reconciliation_ok=true were not produced"
        # false-FINISHed ingest (session c38ad01b) and skipped a real retry.
        exit_match = "count_reconciliation_ok:\\s*\\\"true\\\"|blocked:missing_monolith_state_uri|blocked:three_runner_attempts_failed|blocked:ingest_script_pack_failed|blocked:split_lock_timeout|script_pack_verify_ok:\\s*\\\"false\\\"|script_pack_error="
      }
    },
    {
      stage_id         = "ingest-blocked-gate"
      action_type      = "conditional_skip"
      agent_ref        = ""
      stage_depends_on = ["ingest-split-loop"]
      action_config = {
        condition = "output_matches_regex"
        # Emitted forms only. Do not use script_pack_verify_ok[^\\n]{0,40}false here:
        # loop FINISH reasons paste the exit_match pattern text, and that substring
        # false-skipped a clean split (session cec82df8: count_reconciliation_ok=true,
        # 89 groups) straight to final-gate.
        match   = "blocked:missing_monolith_state_uri:\\s*\\\"true\\\"|blocked:three_runner_attempts_failed:\\s*\\\"true\\\"|blocked:ingest_script_pack_failed:\\s*\\\"true\\\"|blocked:split_lock_timeout:\\s*\\\"true\\\"|stage_summary:ingest-and-split=blocked:|script_pack_verify_ok:\\s*\\\"false\\\"|script_pack_verify_ok=false|count_reconciliation_ok:\\s*\\\"false\\\"|count_reconciliation_ok=false|script_pack_error=[A-Za-z0-9_]"
        skip_to = "final-gate-and-memory"
        reason  = "The scanned resources could not be split correctly, so Terraform generation cannot continue"
      }
    },
    {
      stage_id         = "registry-and-import-codegen"
      agent_ref        = sg_agent.aws_migrator_architect.name
      stage_depends_on = ["ingest-blocked-gate"]
      runbook_refs     = [sg_runbook_sop.discovery_stage_contract.name]
      skill_refs = concat(
        [
          sg_runbook_sop.aws_discovery_pr_review.name,
          sg_runbook_sop.mapping_provider_schema_reasoning.name,
          sg_runbook_sop.mapping_catalog_knowledge.name,
        ],
        try(var.workflow_skill_refs["aws-cloud-discovery::registry-and-import-codegen"], []),
      )
      note = <<-EOT
        Goal: open a PR with the generated AWS Terraform folders, or leave a concrete reason the PR could not open.
        Done when: your stage result includes the batch payloads path and either a PR URL or a real PR blocker from the runner.
        How: ONE `${local.shell_tool_prefix}_execute_series` with `commands[0].command` set to the **exact one-line body** between `---BEGIN IAC_PR_EXECUTE_SERIES---` and `---END---` below (starts with `GIT_TOKEN=` / `WORKFLOW_RUN_ID=` and runs `iac-pr-bootstrap.sh` on the pack). create_agent is fine with the same body.
        **FORBIDDEN:** `command="IAC_PR_EXECUTE_SERIES"` or running the marker label as shell (exit 127). Soft split-quality scores are warnings, not blockers. Never rebuild this one-liner by hand: it contains nested quotes. If the runner returns `/bin/sh: Syntax error: Unterminated quoted string`, the command was mangled; retry only by copying the exact BEGIN/END body unchanged.
        Prefer the pack command over inventing shell. Echo only runner-emitted success or blocker lines; do not paraphrase them away.

        ${local.dbsplit_spawn_context_registry}
      EOT
    },
    {
      stage_id         = "shell-converge-matrix"
      agent_ref        = sg_agent.aws_migrator_architect.name
      stage_depends_on = ["registry-and-import-codegen"]
      runbook_refs     = [sg_runbook_sop.discovery_stage_contract.name]
      skill_refs = concat(
        [sg_runbook_sop.terraform_diagnose_edit_verify.name],
        try(var.workflow_skill_refs["aws-cloud-discovery::shell-converge-matrix"], []),
        try(var.workflow_skill_refs["aws-cloud-discovery::hcl-hydrate-per-group"], []),
      )
      note = <<-EOT
        Goal: hydrate generated Terraform HCL for sampled groups, push it to the discovery PR, and keep fixing until fmt/validate passes when possible. A zero-change plan is nice but optional.
        Done when: the runner printed `terraform_validation_ok: "true"` or `terraform_validation_ok: "false"` (plus sync status). Validation false is not a stage failure and must not skip the PR sync or stop orphan/final stages.
        How: ONE `${local.shell_tool_prefix}_execute_series` pasting the **exact** BEGIN/END `CONVERGE_EXECUTE_SERIES` one-liner (starts with `GIT_TOKEN=` / `WORKFLOW_RUN_ID=` and runs `converge-bootstrap.sh` on the pack); set `timeout_seconds=3600`. The workflow id is passed as argv and the pack entrypoint exports it before invoking the bootstrap. create_agent is fine for HCL fixes.
        **FORBIDDEN:** marker labels as shell. For quoting, `WORKFLOW_RUN_ID_unset`, or paste errors, diagnose argv and retry from this note's BEGIN/END body or last successful call args — never memory or repo/state grep. If argv has the id, `WORKFLOW_RUN_ID_unset` is a wrapper error: fix and retry, even if an earlier retry was used.
        For unknown errors, probe one relevant note/status/log/tool/path, classify paste vs runner/auth/input/IaC, then do one safe idempotent retry if transient. Never rescan AWS or delete a live lock for a converge error. Stop only with a concrete blocker and next action.
        On `blocked:converge_inputs_missing: "true"`: stop; do not invent IDs. If `hcl_fix_target_count>0`, inspect target evidence and surgically edit named blocks before rerunning; no edits means do not repeat. Never truncate/blank HCL. For `signal: killed` / exit 137 / `converge_batch_incomplete: "true"` / `converge_retryable: "true"` / timeout, resume the same pack from checkpoints; no speculative HCL edits. If stdout sentinel is missing, check `aws/artifacts/converge-status.json` (`null` means incomplete); do not claim validation. Keep the discovery PR synced even when validation is false.

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
        # Quoted true OR false (session e210eccd / bfde676a): false-only GO_BACK burned
        # Guild's stage visit cap (5) while max_iterations defaulted above that cap.
        # Same pattern as azure/gcp validate loops. Sync-ok alone must not FINISH
        # (session 1c6b91d6). Prose "No terraform_validation_ok=true" must not FINISH
        # (session 9a0fa0fc) — require the quoted sentinel.
        exit_match = "terraform_validation_ok:\\s*\\\"true\\\"|terraform_validation_ok:\\s*\\\"false\\\"|blocked:remote_runner_tofu_missing|blocked:remote_runner_shell_unavailable|blocked:converge_inputs_missing"
      }
      note = "loop_stage only — no LLM. Exit on quoted terraform_validation_ok true|false or a terminal runner blocker. Missing sentinel, converge_batch_incomplete, or killed truncation GO_BACKs so hydrate can resume; do not FINISH on converge_retryable alone."
    },
    {
      stage_id         = "converge-blocked-gate"
      action_type      = "conditional_skip"
      agent_ref        = ""
      stage_depends_on = ["shell-converge-loop"]
      action_config = {
        condition = "output_matches_regex"
        # Emitted forms only. Never share a bare substring with exit_match that
        # FINISH reasons embed (same class of bug as ingest-blocked-gate).
        # terraform_validation_ok false is intentionally absent — continue to orphans/final.
        match   = "blocked:remote_runner_tofu_missing:\\s*\\\"true\\\"|blocked:remote_runner_shell_unavailable:\\s*\\\"true\\\"|blocked:converge_inputs_missing:\\s*\\\"true\\\""
        skip_to = "final-gate-and-memory"
        reason  = "Shell converge blocked on a terminal runner failure — skip orphan stage"
      }
    },
    {
      stage_id         = "orphans-secondary-pipeline"
      agent_ref        = sg_agent.aws_migrator_architect.name
      stage_depends_on = ["converge-blocked-gate"]
      runbook_refs     = [sg_runbook_sop.discovery_stage_contract.name]
      skill_refs       = try(var.workflow_skill_refs["aws-cloud-discovery::orphans-secondary-pipeline"], [])
      note             = <<-EOT
        Goal: decide whether orphan resources need a follow-on workflow.
        Done when: you skipped because upstream was blocked or the orphans bundle is empty, or you handed off to the orphan workflow.
        How: read notes first. Do not spawn entry-probe, disk-mirror, or bundle-snapshot subagents.
      EOT
    },
    {
      stage_id         = "final-gate-and-memory"
      agent_ref        = sg_agent.aws_migrator_architect.name
      stage_depends_on = ["orphans-secondary-pipeline"]
      runbook_refs     = [sg_runbook_sop.discovery_stage_contract.name]
      skill_refs = concat(
        [sg_runbook_sop.aws_discovery_pr_review.name],
        try(var.workflow_skill_refs["aws-cloud-discovery::final-gate-and-memory"], []),
        try(var.workflow_skill_refs["aws-migrator-discovery::final-gate-and-memory"], []),
      )
      note = <<-EOT
        Goal: close this AWS discovery run for the operator.
        Done when: you reported ready, needs work, or could not generate Terraform, with Result, Checks, and Ways to improve readiness.
        Ready means: scan done, every scanned resource accounted for in exactly one folder, a PR URL (or concrete PR blocker), **all** selected groups hydrated (`hydrate_groups_remaining=0` and each has `generated.tf`), and stub-var `tofu plan` compile-ok (`compile_ok=true` / `terraform_compile_ok_groups` matches). If `hydrate_groups_remaining>0` or `terraform_validation_ok` is false, report **needs work** with the PR link and remaining `hcl_fix_target` lines — never label Result Ready while groups lack generated.tf. Zero-change plan and split-quality reports are optional. Missing Azure or GCP evidence is not a failure here.
      EOT
    },
  ]
}
