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
        description = "Format and validate the generated Terraform"
        note        = "Paste CONVERGE_EXECUTE_SERIES. Goal is terraform_validation_ok; zero-change plan is optional."
        required    = true
      },
      {
        stage_id    = "shell-converge-loop"
        description = "Retry Terraform validation until every sampled group passes or a terminal blocker is emitted"
        note        = "loop_stage only — no LLM. Exit on terraform_validation_ok=true."
        required    = false
      },
      {
        stage_id    = "converge-blocked-gate"
        description = "Skip to final gate when shell converge ended on a terminal runner/validation blocker"
        note        = "conditional_skip only — no LLM."
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
        Done when: the runner reports the preflight succeeded.
        How: prefer the BEGIN/END pack command in this note (paste into `${local.shell_tool_prefix}_execute_series`). create_agent is fine if you put that same body in the expectation. Prefer working_dir omit or `/`. If the call is rejected for working_dir or args, retry once with working_dir unset.
        Prefer the pack command over inventing shell.

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
        Done when: the scan succeeded, the state path is non-empty, and the resource count is greater than zero.
        How: prefer the BEGIN/END pack command in this note (paste into `${local.shell_tool_prefix}_execute_series`). create_agent is fine with the same body. Swap the region placeholder and workflow run id; leave filter quotes empty when the operator did not set filters. Do not append `&&` or invent a different cloud2code invocation.
        On a mangled paste or scan failure: paste the same BEGIN/END body once more before giving up. Prefer the pack command over inventing shell.

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
        # blocked:cloud2code_scan_failed is retryable inside the loop, not an exit.
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
        # Emitted sentinel forms only — loop FINISH reasons paste exit_match text.
        match   = "blocked:missing_aws_region:\\s*\\\"true\\\"|blocked:remote_runner_cloud2code_missing:\\s*\\\"true\\\"|blocked:remote_runner_awscli_missing:\\s*\\\"true\\\"|blocked:remote_runner_jq_missing:\\s*\\\"true\\\"|blocked:cloud2code_scan_failed:\\s*\\\"true\\\"|blocked:cloud2code_tfstate_missing:\\s*\\\"true\\\"|blocked:cloud2code_tfstate_invalid:\\s*\\\"true\\\"|blocked:cloud2code_workflow_run_id_unresolved:\\s*\\\"true\\\"|stage_summary:cloud2code-scan-aws=blocked:"
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
        Done when: reconciliation succeeds, group paths are present, and the script pack verified.
        How: prefer the BEGIN/END pack command in this note (one `${local.shell_tool_prefix}_execute_command`, working_dir `/`, full timeout). create_agent is fine with the same body. Do not ask the operator for the state path; do not invent shell; do not use GitHub or AWS MCP tools for this stage.
        On failure: retry that same paste once. Prefer the pack command over inventing shell.

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
        exit_match     = "count_reconciliation_ok[^\\n]{0,40}true|blocked:missing_monolith_state_uri|blocked:three_runner_attempts_failed|blocked:ingest_script_pack_failed|script_pack_verify_ok[^\\n]{0,40}false|script_pack_error="
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
        match   = "blocked:missing_monolith_state_uri:\\s*\\\"true\\\"|blocked:three_runner_attempts_failed:\\s*\\\"true\\\"|blocked:ingest_script_pack_failed:\\s*\\\"true\\\"|stage_summary:ingest-and-split=blocked:|script_pack_verify_ok:\\s*\\\"false\\\"|script_pack_verify_ok=false|count_reconciliation_ok:\\s*\\\"false\\\"|count_reconciliation_ok=false|script_pack_error=[A-Za-z0-9_]"
        skip_to = "final-gate-and-memory"
        reason  = "The scanned resources could not be split correctly, so Terraform generation cannot continue"
      }
    },
    {
      stage_id         = "registry-and-import-codegen"
      agent_ref        = sg_agent.aws_migrator_architect.name
      stage_depends_on = ["ingest-blocked-gate"]
      runbook_refs     = [sg_runbook_sop.discovery_stage_contract.name]
      skill_refs       = try(var.workflow_skill_refs["aws-cloud-discovery::registry-and-import-codegen"], [])
      note             = <<-EOT
        Goal: open a PR with the generated AWS Terraform folders, or leave a concrete reason the PR could not open.
        Done when: the batch payloads exist and you have a PR URL or a real PR blocker.
        How: prefer the BEGIN/END pack command in this note (paste into `${local.shell_tool_prefix}_execute_series`). create_agent is fine with the same body. Do not hand-roll clone or PR steps. Soft split-quality scores are warnings, not blockers.
        Prefer the pack command over inventing shell.

        ${local.dbsplit_spawn_context_registry}
      EOT
    },
    {
      stage_id         = "shell-converge-matrix"
      agent_ref        = sg_agent.aws_migrator_architect.name
      stage_depends_on = ["registry-and-import-codegen"]
      runbook_refs     = [sg_runbook_sop.discovery_stage_contract.name]
      skill_refs = concat(
        try(var.workflow_skill_refs["aws-cloud-discovery::shell-converge-matrix"], []),
        try(var.workflow_skill_refs["aws-cloud-discovery::hcl-hydrate-per-group"], []),
      )
      note = <<-EOT
        Goal: Terraform fmt and validate succeed on the sampled groups. A zero-change plan is nice but optional.
        Done when: validation is true for the sample, or the runner truly cannot run tofu/shell.
        How: prefer the BEGIN/END pack command in this note. create_agent is fine, especially for fixing HCL on the runner. If fmt or validate fails, fix the generated files and re-run the pack rather than respawning the same goal unchanged.
        Prefer the pack command over inventing shell.

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
        # Soft terraform_validation_ok=false keeps GO_BACK. Do not exit on
        # stage_summary:…=blocked: — FINISH reasons paste exit_match text and
        # false-skipped to final-gate (session 03c3512c).
        exit_match = "terraform_validation_ok[^\\n]{0,40}true|blocked:remote_runner_tofu_missing|blocked:remote_runner_shell_unavailable"
      }
      note = "loop_stage only — no LLM. Exit on terraform_validation_ok true or a terminal runner blocker."
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
        match   = "blocked:remote_runner_tofu_missing:\\s*\\\"true\\\"|blocked:remote_runner_shell_unavailable:\\s*\\\"true\\\""
        skip_to = "final-gate-and-memory"
        reason  = "Shell converge blocked — skip orphan and final destination stages"
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
        try(var.workflow_skill_refs["aws-cloud-discovery::final-gate-and-memory"], []),
        try(var.workflow_skill_refs["aws-migrator-discovery::final-gate-and-memory"], [])
      )
      note = <<-EOT
        Goal: close this AWS discovery run for the operator.
        Done when: you reported ready, needs work, or could not generate Terraform, with Result, Checks, and Ways to improve readiness.
        Success means: scan done, every resource in exactly one folder, readable `.tf` files, fmt and validate pass, and a PR URL or a concrete PR blocker. Zero-change plan and split-quality reports are optional. Missing Azure or GCP evidence is not a failure here.
      EOT
    },
  ]
}
