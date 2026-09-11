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
        Purpose: fail fast if the remote runner lacks tools or the script pack.
        First call: `${local.shell_tool_prefix}_execute_series` with BEGIN/END RUNNER_CAPABILITY_PREFLIGHT_EXECUTE_SERIES. create_agent is allowed; put the same body in expectation. tool_names only that series tool. working_dir omit or /.
        On a rejected call (bad working_dir / bad args): retry once with working_dir unset. Then blocked.
        Done when runner output has `runner_capability_preflight_ok: "true"`. Else `stage_summary:runner-capability-preflight=blocked:missing_runner_evidence`.
        Terminal: blocked:remote_runner_{jq,awscli,python3,git,tofu,opa,cloud2code,script_pack,shell}_* .

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
        # missing_runner_evidence intentionally omitted: worker mishandled the call,
        # not a missing tool. Guild rejects a loop_stage on the entry stage.
        match   = "blocked:remote_runner_jq_missing|blocked:remote_runner_awscli_missing|blocked:remote_runner_python3_missing|blocked:remote_runner_git_missing|blocked:remote_runner_tofu_missing|blocked:remote_runner_opa_missing|blocked:remote_runner_cloud2code_missing|blocked:remote_runner_script_pack_missing|blocked:remote_runner_shell_unavailable"
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
        Purpose: create monolith_state_uri for this run. Downstream stages must not ask the operator for it.
        First call: `${local.shell_tool_prefix}_execute_series` with BEGIN/END CLOUD2CODE_SCAN_EXECUTE_SERIES. Do not create_agent, load_skill, or read_notes first. On loop GO_BACK, paste again — do not re-plan.
        Substitute: region for AWS_REGION_PLACEHOLDER, real workflow_run_id for {{workflow_run_id}}, operator filters into CLOUD2CODE_* quotes (leave empty if unset). Never append &&. Pack runs `cloud2code import aws` — there is no `cloud2code aws` subcommand.
        On mangled paste / unknown command / blocked:cloud2code_scan_failed: discard and paste the same BEGIN/END body again. Terminal blocked:cloud2code_scan_failed only after that retry, or non-retryable credentials.
        Done when runner output has cloud2code_scan_ok true, non-empty monolith_state_uri, and monolith_resource_count > 0. Else stage_summary:cloud2code-scan-aws=blocked:missing_runner_evidence. note those keys.

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
        Purpose: every scanned resource exactly once, each group has a state file. Split-quality scores are optional.
        First call: one `${local.shell_tool_prefix}_execute_command` with BEGIN/END INGEST_BOOTSTRAP_EXECUTE_COMMAND (working_dir=/, full timeout). create_agent is allowed with the same body. Do not ask for monolith_state_uri; do not invent shell; do not use GitHub/AWS MCP tools.
        On failure: retry that same paste once. Then blocked:three_runner_attempts_failed and blocked:ingest_script_pack_failed. If bootstrap prints blocked:missing_monolith_state_uri, note it and return.
        Done when count_reconciliation_ok true, non-empty group paths, and script_pack_verify_ok true. note stage_summary:ingest-and-split and handoff keys. Never submit_evidence here.

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
        Purpose: AWS group Terraform on a branch, plus pr_url or a concrete pr_blocker. Soft split-quality scores are warnings.
        First call: `${local.shell_tool_prefix}_execute_series` with BEGIN/END IAC_PR_EXECUTE_SERIES. Do not create_agent. Do not hand-roll clone/PR. The body is in this note, not a file on the runner.
        Username/github.com clone errors: re-run the same series (it aliases token → GIT_TOKEN). Not a terminal pr_blocker.
        Keep fixing on the runner until batch_payloads_path exists and you have pr_url or a real pr_blocker. note those keys and stage_summary:registry-and-import-codegen.

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
        Purpose: terraform_validation_ok true on sampled groups. Zero-change plan is optional.
        First call: BEGIN/END CONVERGE_EXECUTE_SERIES. create_agent is allowed.
        If fmt/validate fails: fix HCL on the runner and re-check until validation passes or blocked:remote_runner_tofu_missing / blocked:remote_runner_shell_unavailable.
        note terraform_validation_ok, group lists, stage_summary:shell-converge-matrix.

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
        exit_match     = "terraform_validation_ok[^\\n]{0,40}true|blocked:remote_runner_tofu_missing|blocked:remote_runner_shell_unavailable|stage_summary:shell-converge-matrix=blocked:"
      }
      note = "loop_stage only — no LLM. Exit on terraform_validation_ok true or a terminal runner/stage_summary blocker."
    },
    {
      stage_id         = "converge-blocked-gate"
      action_type      = "conditional_skip"
      agent_ref        = ""
      stage_depends_on = ["shell-converge-loop"]
      action_config = {
        condition = "output_matches_regex"
        match     = "blocked:remote_runner_tofu_missing:\\s*\\\"true\\\"|blocked:remote_runner_shell_unavailable:\\s*\\\"true\\\"|stage_summary:shell-converge-matrix=blocked:"
        skip_to   = "final-gate-and-memory"
        reason    = "Shell converge blocked — skip orphan and final destination stages"
      }
    },
    {
      stage_id         = "orphans-secondary-pipeline"
      agent_ref        = sg_agent.aws_migrator_architect.name
      stage_depends_on = ["converge-blocked-gate"]
      runbook_refs     = [sg_runbook_sop.discovery_stage_contract.name]
      skill_refs       = try(var.workflow_skill_refs["aws-cloud-discovery::orphans-secondary-pipeline"], [])
      note             = <<-EOT
        Max 2 tool turns: read_notes → if upstream blocked, note skipped:upstream_blocked and return; if orphans_bundle empty, note skipped:empty_orphans_bundle and return; else hand off to the orphan workflow.
        Forbidden: entry-probe, disk-mirror, or bundle-snapshot subagents.
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
        AWS discovery only. Missing Azure/GCP evidence is not a failure here.
        Success: scan done, every resource in exactly one folder, readable .tf files, fmt+validate pass, PR URL or concrete PR blocker.
        Zero-change plan and split-quality reports are optional.
        note stage_summary:final-gate-and-memory. Operator message: ## Terraform ready / ## Terraform needs work / ## Could not generate Terraform with Result, Checks, Ways to improve readiness.
      EOT
    },
  ]
}
