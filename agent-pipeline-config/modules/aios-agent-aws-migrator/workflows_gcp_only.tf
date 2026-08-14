# =============================================================================
# GCP-only workflow — fetch generated AWS IaC branch → GCP IaC + PR
# =============================================================================

resource "sg_workflow" "aws_migrator_gcp_only" {
  name        = local.workflow_gcp_only_name
  domain      = "infrastructure-as-code"
  description = <<-EOT
    GCP migration PR workflow. Resolves a discovery handoff via `source_pr` (GitHub PR number) or
    `source_iac_branch` (head ref; default `${local.gcp_only_source_branch}`), clones that tip from
    `${trimspace(var.default_iac_repository_url)}`, materializes `aws/groups` + `aws/artifacts`, then runs
    GCP blueprint → HCL generate → validate/live plan → sibling multi-commit GCP PR (`gcp/<run_id>`).
    Skips cloud2code, tfstate split, AWS reverse-HCL hydration, and orphan handling.
  EOT
  approve     = true

  metadata = {
    planner_max_tool_iterations = 8
  }

  lifecycle {
    ignore_changes = [
      metadata,
    ]
  }

  required_inputs = []
  optional_inputs = [
    "source_pr",
    "source_iac_branch",
    "source_iac_repository_url",
    "iac_repository_url",
    "default_branch",
  ]
  evidence_checklist_ref = sg_evidence_checklist.aws_migrator_gcp_only_evidence.name

  example_queries = [
    "Run gcp-migration-pr from source_pr=<discovery PR number> and open a sibling GCP PR",
    "Fetch source_iac_branch=${local.gcp_only_source_branch} from cloud-migrator, generate GCP IaC, validate it, and open a PR",
  ]

  triggers = [
    { field = "intent", values = ["gcp-migration-pr"], type = "passive" },
  ]

  runbook_refs = [
    sg_runbook_sop.azure_demo_migration_profile.name,
    sg_runbook_sop.aws_migrator_orchestration.name,
    sg_runbook_sop.terraform_substate_convergence.name,
  ]

  stages = concat(
    [
      {
        stage_id    = "gcp-source-fetch"
        description = "Clone the split AWS IaC branch and materialize aws/groups plus artifacts into the runner work root"
        note        = "Script-first. Resolve source_pr or source_iac_branch (default ${local.gcp_only_source_branch}); notes can override source_iac_repository_url."
        required    = true
      },
    ],
    local.gcp_pipeline_core_stages,
    [
      {
        stage_id    = "gcp-only-final"
        description = "Submit GCP-only evidence and summarize PR, validation, and review-needed artifacts"
        note        = "No shell. Evidence and final notification only."
        required    = true
      },
    ],
  )


  stage_bindings = [
    {
      stage_id  = "gcp-source-fetch"
      action_config = {}
      agent_ref = sg_agent.aws_migrator_architect.name
      runbook_refs = [
        sg_runbook_sop.azure_demo_migration_profile.name,
        sg_runbook_sop.aws_migrator_orchestration.name,
      ]
      skill_refs = concat(
        [local.sop_azure_migration_name, local.sop_orchestration_name],
        try(var.workflow_skill_refs["gcp-migration-pr::gcp-source-fetch"], [])
      )
      spawn_contracts = local.spawn_contracts_gcp_source_fetch
      note            = <<-EOT
        **Purpose:** start from an already-generated AWS IaC split branch instead of rerunning cloud2code/decomposition.
        **Handoff:** prefer workflow input / note `source_pr` (GitHub PR number) → `gh pr view` head branch; else `source_iac_branch` (default `${local.gcp_only_source_branch}`). Optional `source_iac_repository_url` (default `${trimspace(var.default_iac_repository_url)}`).
        **Incremental bring-up execution (mandatory):** this workspace runs stages in an execution mode that does not expose `create_agent`. Do **not** attempt `create_agent`. Your FIRST tool call must be ONE `${local.shell_tool_prefix}_execute_series` whose single command is the **one-line** body between `---BEGIN GCP_SOURCE_FETCH_EXECUTE_SERIES---` and `---END---` (it starts with `SOURCE_PR=` and ends with `run-destination-stage.sh gcp-source-fetch`). **WRONG:** `command="GCP_SOURCE_FETCH_EXECUTE_SERIES"` (session d6e915ee failed with `not found`). **RIGHT:** paste the full one-liner. **Required edit:** set `SOURCE_PR='<digits>'` from the user prompt (`source_pr=34` or `.../pull/34`) before calling — session 92506cc0 failed with `missing_source_iac_branch` when `SOURCE_PR` stayed empty. Do not rely on a separate `note(source_pr)` call.
        **Hard evidence gate:** completion requires a successful runner result with `gcp_source_iac_fetched=true` and `gcp_source_iac_group_count` greater than zero. Absent those, record `stage_summary:gcp-source-fetch=blocked:missing_runner_evidence` and return blocked — and quote the runner stderr instead of inventing a silent block.
        **Outputs:** `$WORK_ROOT/groups`, `$WORK_ROOT/logical_group_manifest.json`, `$WORK_ROOT/source_aws/`, notes `gcp_source_iac_fetched=true`, `gcp_source_iac_group_count`, `source_iac_repository_url`, `source_iac_branch`, and `stage_summary:gcp-source-fetch=ok`.
        **Forbidden:** cloud2code, tfstate splitting, AWS reverse-HCL hydration, StackGen MCP tools, AppStacks, or asking for the branch path.

        The exact spawn/direct-fallback context follows. It is embedded here so
        the architect can execute the same series when subagent creation is
        unavailable instead of inventing a replacement command:

        ${local.dbsplit_spawn_context_gcp_source_fetch}
      EOT
    },
    {
      stage_id         = "gcp-migration-blueprint"
      action_config = {}
      agent_ref        = sg_agent.aws_migrator_architect.name
      stage_depends_on = ["gcp-source-fetch"]
      runbook_refs = [
        sg_runbook_sop.azure_demo_migration_profile.name,
        sg_runbook_sop.aws_migrator_orchestration.name,
      ]
      skill_refs = concat(
        [local.sop_azure_migration_name, local.sop_orchestration_name],
        try(var.workflow_skill_refs["gcp-migration-pr::gcp-migration-blueprint"], [])
      )
      spawn_contracts = local.spawn_contracts_gcp_only_blueprint
      note            = <<-EOT
        **Upstream guard:** if `gcp_source_iac_fetched` is not `"true"` or notes contain `blocked:gcp_source_iac_fetch_failed`, record `stage_summary:gcp-migration-blueprint=skipped:source_fetch_failed` and return.
        **No-approval GCP profile:** use `${local.sop_azure_migration_name}`. Do not call StackGen MCP tools, do not create AppStacks, and do not ask clarifying questions for service choices.
        **Incremental bring-up execution (mandatory):** this workspace runs stages in an execution mode that does not expose `create_agent`. Do **not** attempt `create_agent`, and never report this stage blocked because a subagent could not be spawned. Your FIRST tool call must be ONE `${local.shell_tool_prefix}_execute_series` whose single command is the ONE-LINE body between BEGIN/END GCP_BLUEPRINT_EXECUTE_SERIES (`WORKFLOW_RUN_ID=` … `run-destination-stage.sh gcp-migration-blueprint`). Never pass the marker name as the command.
        **Hard evidence gate:** completion requires a successful runner result with `gcp_migration_blueprint_ok=true` and `gcp_blueprint_group_count` greater than zero. Absent those, record `stage_summary:gcp-migration-blueprint=blocked:missing_runner_evidence` and return blocked.
        **Outputs:** `gcp/artifacts/migration-profile.json`, `gcp/artifacts/migration-blueprint.json`, `gcp/artifacts/review-needed.md`, notes `gcp_migration_blueprint_ok=true`, `gcp_blueprint_group_count`, and `stage_summary:gcp-migration-blueprint=ok`.

        ${local.dbsplit_spawn_context_gcp_blueprint}
      EOT
    },
    {
      stage_id         = "gcp-iac-generate"
      action_config = {}
      agent_ref        = sg_agent.aws_migrator_architect.name
      stage_depends_on = ["gcp-migration-blueprint"]
      runbook_refs = [
        sg_runbook_sop.azure_demo_migration_profile.name,
        sg_runbook_sop.aws_migrator_orchestration.name,
      ]
      skill_refs = concat(
        [local.sop_azure_migration_name, local.sop_orchestration_name],
        try(var.workflow_skill_refs["gcp-migration-pr::gcp-iac-generate"], [])
      )
      spawn_contracts = local.spawn_contracts_gcp_only_generate
      note            = <<-EOT
        **Upstream guard:** if `gcp_migration_blueprint_ok` is not `"true"`, record `stage_summary:gcp-iac-generate=skipped:blueprint_missing` and return.
        **Incremental bring-up execution (mandatory):** this workspace runs stages in an execution mode that does not expose `create_agent`. Do **not** attempt `create_agent`. Your FIRST tool call must be ONE `${local.shell_tool_prefix}_execute_series` whose single command is the ONE-LINE body between BEGIN/END GCP_GENERATE_EXECUTE_SERIES (`run-destination-stage.sh gcp-iac-generate`). Never pass the marker name as the command.
        **Mapping rule:** make best-effort GCP equivalents using the default profile. Generate a valid scaffold when exact equivalence is uncertain and document it in `gcp/artifacts/review-needed.md`; never block on human approval. Generate HCL only under `$WORK_ROOT/gcp/groups/<group_id>/`.
        **Hard evidence gate:** completion requires a successful runner result with `gcp_iac_generated=true` and `gcp_iac_group_count` greater than zero. Absent those, record `stage_summary:gcp-iac-generate=blocked:missing_runner_evidence` and return blocked.
        **Outputs:** note `gcp_iac_generated=true`, `gcp_iac_group_count`, `gcp_generation_summary_path`, `gcp_mapping_decisions_path`, and `stage_summary:gcp-iac-generate=ok`.

        ${local.dbsplit_spawn_context_gcp_generate}
      EOT
    },
    {
      stage_id         = "gcp-iac-validate"
      action_config = {}
      agent_ref        = sg_agent.aws_migrator_architect.name
      stage_depends_on = ["gcp-iac-generate"]
      runbook_refs = [
        sg_runbook_sop.azure_demo_migration_profile.name,
        sg_runbook_sop.terraform_substate_convergence.name,
        sg_runbook_sop.aws_migrator_orchestration.name,
      ]
      skill_refs = concat(
        [local.sop_azure_migration_name, local.sop_substate_converge_name, local.sop_orchestration_name],
        try(var.workflow_skill_refs["gcp-migration-pr::gcp-iac-validate"], [])
      )
      spawn_contracts = local.spawn_contracts_gcp_only_validate
      note            = <<-EOT
        **Upstream guard:** if `gcp_iac_generated` is not `"true"`, record `stage_summary:gcp-iac-validate=skipped:generation_missing` and return.
        **Incremental bring-up execution (mandatory):** this workspace runs stages in an execution mode that does not expose `create_agent`. Do **not** attempt `create_agent`. Your FIRST tool call must be ONE `${local.shell_tool_prefix}_execute_series` whose single command is the ONE-LINE body between BEGIN/END GCP_VALIDATE_EXECUTE_SERIES (`run-destination-stage.sh gcp-iac-validate`). Never pass the marker name as the command. Set `timeout_seconds=7200` on that execute_series call — live GCP plan across hundreds of groups routinely exceeds 30 minutes.
        **Validation contract:** when `REQUIRE_GCP_LIVE_PLAN=1`, `gcp_plan_status` must start with `success` (exact `success` or `success:sample:N/M`); missing credentials is a hard fail. Never run `tofu apply` on migrated GCP resources.
        **Validation contract:** run `tofu fmt`, `tofu validate`, optional `tofu test`, optional `tflint`, and live `tofu plan` (never apply). When `REQUIRE_GCP_LIVE_PLAN=1`, missing credentials fail the stage.
        **Hard evidence gate:** completion requires a successful runner result carrying `gcp_iac_validation_ok` and a non-empty `gcp_iac_validation_report`. Absent those, record `stage_summary:gcp-iac-validate=blocked:missing_runner_evidence` and return blocked.
        **Outputs:** note `gcp_iac_validation_ok`, `gcp_plan_status`, `gcp_iac_validation_report`, and `stage_summary:gcp-iac-validate`.

        ${local.dbsplit_spawn_context_gcp_validate}
      EOT
    },
    {
      stage_id         = "gcp-iac-harden"
      agent_ref        = sg_agent.aws_migrator_architect.name
      stage_depends_on = ["gcp-iac-generate"]
      # Explicit empty clears a prior Guild merge-by-index bleed: inserting this
      # stage shifted gcp-iac-loop down one slot and left action_type=loop_stage
      # + validate exit_match on harden (0ms GO_BACK, no agent/runner work).
      action_type   = ""
      action_config = {}
      runbook_refs = [
        sg_runbook_sop.azure_demo_migration_profile.name,
        sg_runbook_sop.aws_migrator_orchestration.name,
      ]
      skill_refs = concat(
        [local.sop_azure_migration_name, local.sop_orchestration_name],
        try(var.workflow_skill_refs["gcp-migration-pr::gcp-iac-harden"], [])
      )
      spawn_contracts = local.spawn_contracts_gcp_only_harden
      note            = <<-EOT
        **Upstream guard:** if `gcp_iac_generated` is not `"true"`, record `stage_summary:gcp-iac-harden=skipped:generation_missing` and return.
        **Parallel with validate:** this stage shares `stage_depends_on=gcp-iac-generate` with `gcp-iac-validate` (Guild DAG fan-out). Do not wait for validate.
        **Incremental bring-up execution (mandatory):** this workspace runs stages in an execution mode that does not expose `create_agent`. Do **not** attempt `create_agent`. Your FIRST tool call must be ONE `${local.shell_tool_prefix}_execute_series` whose single command is the ONE-LINE body between BEGIN/END GCP_HARDEN_EXECUTE_SERIES (`run-destination-stage.sh gcp-iac-harden`). Never pass the marker name as the command. Set `timeout_seconds=3600`.
        **Harden contract:** run mechanical autofix (`destination_iac_harden.py`), `tofu fmt`, optional `tflint --fix`, and checkov/tfsec/trivy when installed. Apply fixes under `gcp/groups/` so they ship in the same PR. Do **not** invent IAM translations or network redesigns.
        **Hard evidence gate:** completion requires `gcp_iac_harden_ok=true` and a non-empty `gcp_iac_harden_report`. Absent those, record `stage_summary:gcp-iac-harden=blocked:missing_runner_evidence` and return blocked.
        **Outputs:** note `gcp_iac_harden_ok`, `gcp_iac_harden_report`, `gcp_iac_harden_findings`, `gcp_iac_harden_autofix_count`, and `stage_summary:gcp-iac-harden=ok`.

        ${local.dbsplit_spawn_context_gcp_harden}
      EOT
    },
    {
      stage_id         = "gcp-iac-loop"
      action_type      = "loop_stage"
      agent_ref        = ""
      stage_depends_on = ["gcp-iac-validate"]
      # Clear residuals left when harden was inserted ahead of this slot (old
      # gcp-pr note/spawn_contracts otherwise stick on the loop binding).
      runbook_refs    = []
      skill_refs      = []
      spawn_contracts = []
      note            = "Deterministic validate→generate loop gate. No agent."
      action_config = {
        loop_to        = "gcp-iac-generate"
        max_iterations = var.max_convergence_iterations
        exit_condition = "output_matches_regex"
        # Destination generate is deterministic — re-entering generate will not heal tofu
        # init/static failures or missing credentials. Exit the loop on ANY conclusive
        # validate result (quoted true OR false) or an explicit blocked stage_summary so
        # we proceed to gcp-pr instead of aborting on Guild's stage visit cap.
        exit_match = "gcp_iac_validation_ok[^\\n]{0,40}\"true\"|gcp_iac_validation_ok[^\\n]{0,40}\"false\"|stage_summary:gcp-iac-validate=ok|stage_summary:gcp-iac-validate=blocked:|stage_summary:gcp-iac-validate=skipped:|stage_summary:gcp-iac-generate=skipped:|stage_summary:gcp-migration-blueprint=skipped:|stage_summary:gcp-source-fetch=blocked:|blocked:gcp_source_iac_fetch_failed|blocked:remote_runner_tofu_missing|blocked:remote_runner_shell_unavailable|GCP_SOURCE_FETCH_EXECUTE_SERIES: not found"
      }
    },
    {
      stage_id         = "gcp-pr"
      action_config = {}
      agent_ref        = sg_agent.aws_migrator_architect.name
      stage_depends_on = ["gcp-iac-loop", "gcp-iac-harden"]
      runbook_refs = [
        sg_runbook_sop.azure_demo_migration_profile.name,
        sg_runbook_sop.aws_migrator_orchestration.name,
      ]
      skill_refs = concat(
        [local.sop_azure_migration_name, local.sop_orchestration_name],
        try(var.workflow_skill_refs["gcp-migration-pr::gcp-pr"], [])
      )
      spawn_contracts = local.spawn_contracts_gcp_only_pr
      note            = <<-EOT
        **Fan-in:** waits for `gcp-iac-loop` (validate path) and `gcp-iac-harden` so lint/security autofixes are included in the same PR tree.
        **Incremental bring-up execution (mandatory):** this workspace runs stages in an execution mode that does not expose `create_agent`. Do **not** attempt `create_agent`. Your FIRST tool call must be ONE `${local.shell_tool_prefix}_execute_series` whose single command is the ONE-LINE body between BEGIN/END GCP_PR_EXECUTE_SERIES (`run-destination-stage.sh gcp-pr`). Never pass the marker name as the command.
        **Repo contract:** sync `$WORK_ROOT/gcp/` to `${trimspace(var.default_iac_repository_url)}` under `gcp/`, create a fresh branch starting with `gcp/<workflow_run_id>`, and open a new PR against `${trimspace(var.default_branch)}`. If that branch already exists locally/remotely or has any PR history, append a timestamp/PID suffix; never reuse or update an existing PR for a new execution.
        **Hard evidence gate:** read `--- stage_evidence ---` from the execute_series stdout (emitted before the noisy transcript tail). If it contains `gcp_pr_url=https://` or `stage_summary:gcp-pr=ok`, you MUST `note()` those values and complete successfully — never emit `missing_runner_evidence` when those lines are present. Only emit `stage_summary:gcp-pr=blocked:missing_runner_evidence` when neither `gcp_pr_url=` / `pr_url=` nor `pr_blocker=` appears in stage_evidence. An explicit `pr_blocker=` is also a conclusive result (note it and return blocked with that reason).
        **Outputs:** note `gcp_pr_url`, `pr_url`, `gcp_working_branch`, and `stage_summary:gcp-pr=ok` (or the pr_blocker summary).

        ${local.dbsplit_spawn_context_gcp_pr}
      EOT
    },
    {
      stage_id         = "gcp-only-final"
      action_config = {}
      agent_ref        = sg_agent.aws_migrator_architect.name
      stage_depends_on = ["gcp-pr"]
      runbook_refs = [
        sg_runbook_sop.azure_demo_migration_profile.name,
        sg_runbook_sop.aws_migrator_orchestration.name,
      ]
      skill_refs = concat(
        [local.sop_azure_migration_name, local.sop_orchestration_name],
        try(var.workflow_skill_refs["gcp-migration-pr::gcp-only-final"], [])
      )
      note = <<-EOT
        **Blocked guards:** if notes or prior stage outputs contain `blocked:gcp_source_iac_fetch_failed`, `blocked:remote_runner_shell_unavailable`, `blocked:remote_runner_tofu_missing`, or `stage_summary:gcp-pr=blocked:` → `notify` + `stage_summary:gcp-only-final=blocked:<reason>` and return. Do **not** treat `stage_summary:gcp-iac-validate=blocked:` alone as a final blocker when a non-empty `gcp_pr_url` / `pr_url` exists — destination generate is deterministic and the PR documents review-needed.
        **Completion guards:** require evidence that each prior stage concluded. Prefer workflow notes when present; when a note key is absent, accept a prior-stage summary that already carried the same fact (`gcp_source_iac_fetched=true`, `gcp_migration_blueprint_ok=true`, `gcp_iac_generated=true`, a conclusive `gcp_iac_validation_ok` of `"true"` or `"false"` / `stage_summary:gcp-iac-validate=ok|blocked:…`, `gcp_iac_harden_ok=true` / `stage_summary:gcp-iac-harden=ok|blocked:…`, and a non-empty `gcp_pr_url` or `pr_url`). Do **not** block solely because `read_notes` is missing keys that earlier stages already reported in their outputs. Destination generate is deterministic — `validation_ok=false` with an open PR that documents review-needed is a valid finish, not a reason to re-enter generate. When GCP credentials are wired and validation passed, prefer `gcp_plan_status` starting with `success` (including `success:sample:N/M`); when validation failed, report plan_status as recorded.
        **Evidence gate:** submit evidence for `gcp_source_iac_fetched`, `gcp_migration_blueprint_recorded`, `gcp_iac_generated`, `gcp_iac_validation_evidence`, `gcp_iac_harden_evidence`, and `gcp_pr_url_recorded` using those facts.
        **Final message:** include source repo/branch, generated group count, validation status, harden autofix/finding counts, plan status, PR URL, and review-needed artifact path. Note `stage_summary:gcp-only-final=ok`.
      EOT
    },
  ]
}

