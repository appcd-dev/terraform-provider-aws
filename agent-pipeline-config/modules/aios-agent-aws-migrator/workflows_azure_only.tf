# =============================================================================
# Azure-only workflow — fetch generated AWS IaC branch → Azure IaC + PR
# =============================================================================

resource "sg_workflow" "aws_migrator_azure_only" {
  name        = local.workflow_azure_only_name
  domain      = "infrastructure-as-code"
  description = <<-EOT
    Azure migration PR workflow. Resolves a discovery handoff via `source_pr` (GitHub PR number) or
    `source_iac_branch` (head ref; default `${local.azure_only_source_branch}`), clones that tip from
    `${trimspace(var.default_iac_repository_url)}`, materializes `aws/groups` + `aws/artifacts`, then runs
    Azure blueprint → HCL generate → parallel validate/harden/governance-conform → sibling multi-commit Azure PR (`azure/<run_id>`) with living Nile Priority-1 + OPA evidence (residuals documented in TODO when not yet clear).
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
  evidence_checklist_ref = sg_evidence_checklist.aws_migrator_azure_only_evidence.name

  example_queries = [
    "Run azure-migration-pr from source_pr=<discovery PR number> and open a sibling Azure PR",
    "Fetch source_iac_branch=${local.azure_only_source_branch} from cloud-migrator, generate Azure IaC, validate it, and open a PR",
  ]

  triggers = [
    { field = "intent", values = ["azure-migration-pr"], type = "passive" },
  ]

  runbook_refs = [
    sg_runbook_sop.azure_demo_migration_profile.name,
    sg_runbook_sop.nile_governance_learn_and_conform.name,
    sg_runbook_sop.aws_migrator_orchestration.name,
    sg_runbook_sop.terraform_substate_convergence.name,
  ]

  stages = concat(
    [
      {
        stage_id    = "azure-source-fetch"
        description = "Clone the split AWS IaC branch and materialize aws/groups plus artifacts into the runner work root"
        note        = "Script-first. Resolve source_pr or source_iac_branch (default ${local.azure_only_source_branch}); notes can override source_iac_repository_url."
        required    = true
      },
    ],
    local.azure_pipeline_core_stages,
    [
      {
        stage_id    = "azure-only-final"
        description = "Submit Azure-only evidence and summarize PR, validation, and review-needed artifacts"
        note        = "No shell. Evidence and final notification only."
        required    = true
      },
    ],
  )


  stage_bindings = [
    {
      stage_id      = "azure-source-fetch"
      action_config = {}
      agent_ref     = sg_agent.aws_migrator_architect.name
      runbook_refs = [
        sg_runbook_sop.azure_demo_migration_profile.name,
        sg_runbook_sop.aws_migrator_orchestration.name,
      ]
      skill_refs = concat(
        [local.sop_azure_migration_name, local.sop_orchestration_name],
        try(var.workflow_skill_refs["azure-migration-pr::azure-source-fetch"], [])
      )
      note = <<-EOT
        **Purpose:** start from an already-generated AWS IaC split branch instead of rerunning cloud2code/decomposition.
        **Handoff:** prefer workflow input / note `source_pr` (GitHub PR number) → `gh pr view` head branch; else `source_iac_branch` (default `${local.azure_only_source_branch}`). Optional `source_iac_repository_url` (default `${trimspace(var.default_iac_repository_url)}`).
        **Incremental bring-up execution (mandatory):** `create_agent` is allowed (reactree). Put the exact BEGIN/END one-liner in CREATE_AGENT_EXPECTATION (`tool_names` only execute_series), or paste it yourself. ONE `${local.shell_tool_prefix}_execute_series` with `commands[0].command` set to the **exact character-for-character** one-line body between `---BEGIN AZURE_SOURCE_FETCH_EXECUTE_SERIES---` and `---END AZURE_SOURCE_FETCH_EXECUTE_SERIES---` (starts with `SOURCE_PR=`, downloads `pack-entry.sh`, ends with `destination azure-source-fetch`). **FORBIDDEN:** (1) `command="AZURE_SOURCE_FETCH_EXECUTE_SERIES"`; (2) pasting only `BEGIN` or a fragment; (3) composing your own shell; (4) rewriting the pack path. **RIGHT:** copy the full one-line BEGIN/END body unchanged; if user input has `source_iac_branch=…`, set only the `SOURCE_IAC_BRANCH='…'` segment.
        **Hard evidence gate:** completion requires a successful runner result with `azure_source_iac_fetched=true` and `azure_source_iac_group_count` greater than zero. Absent those, record `stage_summary:azure-source-fetch=blocked:missing_runner_evidence` and return blocked.
        **Outputs:** `$WORK_ROOT/groups`, `$WORK_ROOT/logical_group_manifest.json`, `$WORK_ROOT/source_aws/`, notes `azure_source_iac_fetched=true`, `azure_source_iac_group_count`, `source_iac_repository_url`, `source_iac_branch`, and `stage_summary:azure-source-fetch=ok`.
        **Forbidden:** cloud2code, tfstate splitting, AWS reverse-HCL hydration, StackGen MCP tools, AppStacks, or asking for the branch path.

        The exact spawn context follows. Put this BEGIN/END body in CREATE_AGENT_EXPECTATION
        (or paste it yourself). Never invent a replacement command:

        ${local.dbsplit_spawn_context_azure_source_fetch}
      EOT
    },
    {
      stage_id         = "azure-migration-blueprint"
      action_config    = {}
      agent_ref        = sg_agent.aws_migrator_architect.name
      stage_depends_on = ["azure-source-fetch"]
      runbook_refs = [
        sg_runbook_sop.azure_demo_migration_profile.name,
        sg_runbook_sop.aws_migrator_orchestration.name,
      ]
      skill_refs = concat(
        [local.sop_azure_migration_name, local.sop_orchestration_name],
        try(var.workflow_skill_refs["azure-migration-pr::azure-migration-blueprint"], [])
      )
      note = <<-EOT
        **Upstream guard:** if `azure_source_iac_fetched` is not `"true"` or notes contain `blocked:azure_source_iac_fetch_failed`, record `stage_summary:azure-migration-blueprint=skipped:source_fetch_failed` and return.
        **No-approval Azure profile:** use `${local.sop_azure_migration_name}`. Do not call StackGen MCP tools, do not create AppStacks, and do not ask clarifying questions for service choices.
        **Incremental bring-up execution (mandatory):** `create_agent` is allowed (reactree). Put the exact BEGIN/END one-liner in CREATE_AGENT_EXPECTATION (`tool_names` only execute_series), or paste it yourself. ONE `${local.shell_tool_prefix}_execute_series` whose single command is ONLY the shell script between ---BEGIN AZURE_BLUEPRINT_EXECUTE_SERIES--- and ---END AZURE_BLUEPRINT_EXECUTE_SERIES--- below (never use the marker label as the command). Never compose your own shell.
        **Hard evidence gate:** completion requires a successful runner result with `azure_migration_blueprint_ok=true` and `azure_blueprint_group_count` greater than zero. Absent those, record `stage_summary:azure-migration-blueprint=blocked:missing_runner_evidence` and return blocked.
        **Outputs:** `azure/artifacts/migration-profile.json`, `azure/artifacts/migration-blueprint.json`, `azure/artifacts/review-needed.md`, notes `azure_migration_blueprint_ok=true`, `azure_blueprint_group_count`, and `stage_summary:azure-migration-blueprint=ok`.

        ${local.dbsplit_spawn_context_azure_blueprint}
      EOT
    },
    {
      stage_id         = "azure-iac-generate"
      action_config    = {}
      agent_ref        = sg_agent.aws_migrator_architect.name
      stage_depends_on = ["azure-migration-blueprint"]
      runbook_refs = [
        sg_runbook_sop.azure_demo_migration_profile.name,
        sg_runbook_sop.aws_migrator_orchestration.name,
      ]
      skill_refs = concat(
        [local.sop_azure_migration_name, local.sop_orchestration_name],
        try(var.workflow_skill_refs["azure-migration-pr::azure-iac-generate"], [])
      )
      note = <<-EOT
        **Upstream guard:** if `azure_migration_blueprint_ok` is not `"true"`, record `stage_summary:azure-iac-generate=skipped:blueprint_missing` and return.
        **Incremental bring-up execution (mandatory):** `create_agent` is allowed (reactree). Put the exact BEGIN/END one-liner in CREATE_AGENT_EXPECTATION (`tool_names` only execute_series), or paste it yourself. ONE `${local.shell_tool_prefix}_execute_series` whose single command is ONLY the shell script between ---BEGIN AZURE_GENERATE_EXECUTE_SERIES--- and ---END AZURE_GENERATE_EXECUTE_SERIES--- below (never use the marker label as the command).
        **Mapping rule:** make best-effort Azure equivalents using the default profile. Generate a valid scaffold when exact equivalence is uncertain and document it in `azure/artifacts/review-needed.md`; never block on human approval. Generate HCL only under `$WORK_ROOT/azure/groups/<group_id>/`.
        **Hard evidence gate:** completion requires a successful runner result with `azure_iac_generated=true` and `azure_iac_group_count` greater than zero. Absent those, record `stage_summary:azure-iac-generate=blocked:missing_runner_evidence` and return blocked.
        **Outputs:** note `azure_iac_generated=true`, `azure_iac_group_count`, `azure_generation_summary_path`, `azure_mapping_decisions_path`, and `stage_summary:azure-iac-generate=ok`.

        ${local.dbsplit_spawn_context_azure_generate}
      EOT
    },
    {
      stage_id         = "azure-iac-validate"
      action_config    = {}
      agent_ref        = sg_agent.aws_migrator_architect.name
      stage_depends_on = ["azure-iac-generate"]
      runbook_refs = [
        sg_runbook_sop.azure_demo_migration_profile.name,
        sg_runbook_sop.terraform_substate_convergence.name,
        sg_runbook_sop.aws_migrator_orchestration.name,
      ]
      skill_refs = concat(
        [local.sop_azure_migration_name, local.sop_substate_converge_name, local.sop_orchestration_name],
        try(var.workflow_skill_refs["azure-migration-pr::azure-iac-validate"], [])
      )
      note = <<-EOT
        **Upstream guard:** if `azure_iac_generated` is not `"true"`, record `stage_summary:azure-iac-validate=skipped:generation_missing` and return.
        **Incremental bring-up execution (mandatory):** `create_agent` is allowed (reactree). Put the exact BEGIN/END one-liner in CREATE_AGENT_EXPECTATION (`tool_names` only execute_series), or paste it yourself. ONE `${local.shell_tool_prefix}_execute_series` whose single command is ONLY the shell script between ---BEGIN AZURE_VALIDATE_EXECUTE_SERIES--- and ---END AZURE_VALIDATE_EXECUTE_SERIES--- below (never use the marker label as the command). Set `timeout_seconds=7200` on that execute_series call — live Azure plan across hundreds of groups routinely exceeds 30 minutes.
        **Deadline resume:** if execute_series ends with `context deadline exceeded`, `signal: killed`, or incomplete `azure_iac_validate_progress` without a conclusive `azure_iac_validation_ok`, **re-paste the identical BEGIN/END body** (validate-groups resume skips finished groups). Do **not** invent `skipped:` from a partial run.
        **Validation contract:** when `REQUIRE_AZURE_LIVE_PLAN=1`, `azure_plan_status` must start with `success` (exact `success` or `success:sample:N/M`); missing credentials is a hard fail. Never run `tofu apply` on migrated Azure resources.
        **Validation contract:** run `tofu fmt`, `tofu validate`, optional `tofu test`, optional `tflint`, and live `tofu plan` (never apply). When `REQUIRE_AZURE_LIVE_PLAN=1`, missing credentials fail the stage.
        **Hard evidence gate:** completion requires a successful runner result carrying `azure_iac_validation_ok` and a non-empty `azure_iac_validation_report`. Absent those, record `stage_summary:azure-iac-validate=blocked:missing_runner_evidence` and return blocked.
        **On static fails (remediate until useful):** if `azure_iac_validation_ok=false` with static fails, read validation-report / hcl_fix_targets, patch HCL under `azure/groups/`, stub vars, document assumptions in `azure/artifacts/governance-assumptions.md` when inventing values, and re-paste validate. Do not accept false until the validate loop exits.
        **Outputs:** note `azure_iac_validation_ok`, `azure_plan_status`, `azure_iac_validation_report`, and `stage_summary:azure-iac-validate`.

        ${local.dbsplit_spawn_context_azure_validate}
      EOT
    },
    {
      stage_id         = "azure-iac-harden"
      agent_ref        = sg_agent.aws_migrator_architect.name
      stage_depends_on = ["azure-iac-generate"]
      # Explicit empty clears a prior Guild merge-by-index bleed: inserting this
      # stage shifted azure-iac-loop down one slot and left action_type=loop_stage
      # + validate exit_match on harden (0ms GO_BACK, no agent/runner work).
      action_type   = ""
      action_config = {}
      runbook_refs = [
        sg_runbook_sop.azure_demo_migration_profile.name,
        sg_runbook_sop.aws_migrator_orchestration.name,
      ]
      skill_refs = concat(
        [local.sop_azure_migration_name, local.sop_orchestration_name],
        try(var.workflow_skill_refs["azure-migration-pr::azure-iac-harden"], [])
      )
      note = <<-EOT
        **Upstream guard:** if `azure_iac_generated` is not `"true"`, record `stage_summary:azure-iac-harden=skipped:generation_missing` and return.
        **Parallel with validate:** this stage shares `stage_depends_on=azure-iac-generate` with `azure-iac-validate` (Guild DAG fan-out). Do not wait for validate.
        **Incremental bring-up execution (mandatory):** `create_agent` is allowed (reactree). Put the exact BEGIN/END one-liner in CREATE_AGENT_EXPECTATION (`tool_names` only execute_series), or paste it yourself. ONE `${local.shell_tool_prefix}_execute_series` whose single command is ONLY the shell script between ---BEGIN AZURE_HARDEN_EXECUTE_SERIES--- and ---END AZURE_HARDEN_EXECUTE_SERIES--- below (never use the marker label as the command). Set `timeout_seconds=3600`.
        **Harden contract:** run mechanical autofix (`destination_iac_harden.py`), `tofu fmt`, optional `tflint --fix`, and checkov/tfsec/trivy when installed. Apply fixes under `azure/groups/` so they ship in the same PR. Do **not** invent IAM translations or network redesigns.
        **Hard evidence gate:** completion requires `azure_iac_harden_ok=true` and a non-empty `azure_iac_harden_report`. Absent those, record `stage_summary:azure-iac-harden=blocked:missing_runner_evidence` and return blocked.
        **Outputs:** note `azure_iac_harden_ok`, `azure_iac_harden_report`, `azure_iac_harden_findings`, `azure_iac_harden_autofix_count`, and `stage_summary:azure-iac-harden=ok`.

        ${local.dbsplit_spawn_context_azure_harden}
      EOT
    },
    {
      stage_id         = "azure-iac-governance-conform"
      agent_ref        = sg_agent.aws_migrator_architect.name
      stage_depends_on = ["azure-iac-generate"]
      # Explicit empty clears merge-by-index bleed from azure-iac-loop (loop_stage).
      action_type   = ""
      action_config = {}
      runbook_refs = [
        sg_runbook_sop.nile_governance_learn_and_conform.name,
        sg_runbook_sop.azure_demo_migration_profile.name,
        sg_runbook_sop.aws_migrator_orchestration.name,
      ]
      skill_refs = concat(
        [local.sop_governance_conform_name, local.sop_azure_migration_name, local.sop_orchestration_name],
        try(var.workflow_skill_refs["azure-migration-pr::azure-iac-governance-conform"], [])
      )
      note = <<-EOT
        **Upstream guard:** if `azure_iac_generated` is not `"true"`, record `stage_summary:azure-iac-governance-conform=skipped:generation_missing` and return.
        **Parallel with validate/harden:** this stage shares `stage_depends_on=azure-iac-generate` (Guild DAG fan-out). Do not wait for plan or harden.
        **Living docs + OPA:** first tool call is ONE `${local.shell_tool_prefix}_execute_series` whose single command is ONLY the shell script between ---BEGIN AZURE_GOVERNANCE_CONFORM_EXECUTE_SERIES--- and ---END AZURE_GOVERNANCE_CONFORM_EXECUTE_SERIES--- below (`timeout_seconds=3600`) — harness refreshes Governance-and-Policy, inventories resources, seeds/runs the validator, and runs Nile-Factory `rules/` OPA against plan JSON. Then **continue** (not paste-only): load `${local.sop_governance_conform_name}`, rebuild `azure/artifacts/governance-decision-tree.json` from **this-run** docs, `${local.shell_tool_prefix}_create_files` the validator (drop `NILE_GOVERNANCE_VALIDATOR_SCAFFOLD`), read `azure/artifacts/governance-opa-guidance.json` and fix hints when OPA denies; reason about the source, provider schema, and planned value, make the HCL/generator/policy edit yourself at the correct layer, document assumptions, and re-run until `azure_iac_governance_ok=true`. Do not repeat an edit when the OPA findings fingerprint is unchanged. Do not invent controls absent from refreshed docs. Validation evidence is not human approval.
        **Hard evidence gate:** require notes `azure_iac_governance_ok` (`true` or `false`) plus `azure_governance_commit_sha` / `azure/artifacts/governance-source.json`. Docs-unavailable → `blocked:governance_docs_unavailable`. OPA/rules unavailable → `blocked:governance_opa_unavailable`. Nonconformant visits must remediate OPA/validator residuals and re-run until `azure_iac_governance_ok=true` (loop exits on true or terminal blockers / max iterations). If residuals remain, `azure-pr` still opens and documents them in `TODO.md` + PR body.
        **Outputs:** note `azure_iac_governance_ok`, `azure_iac_governance_report`, `azure_iac_opa_report`, `azure_iac_opa_fix_hints`, `azure_governance_commit_sha`, and `stage_summary:azure-iac-governance-conform`.

        ${local.dbsplit_spawn_context_azure_governance_conform}
      EOT
    },
    {
      stage_id         = "azure-iac-loop"
      action_type      = "loop_stage"
      agent_ref        = ""
      stage_depends_on = ["azure-iac-validate"]
      # Clear residuals left when harden/governance were inserted ahead of this slot.
      runbook_refs = []
      skill_refs   = []
      note         = "Deterministic validate remediates loop. No agent."
      action_config = {
        loop_to        = "azure-iac-validate"
        max_iterations = var.max_validate_iterations
        exit_condition = "output_matches_regex"
        # Remediates until useful: exit on validation_ok=true or terminal blockers only.
        exit_match = "azure_iac_validation_ok[^\\n]{0,40}\"true\"|stage_summary:azure-iac-validate=ok|stage_summary:azure-iac-validate=blocked:|blocked:missing_azure_credentials|blocked:remote_runner_tofu_missing|blocked:remote_runner_shell_unavailable"
      }
    },
    {
      stage_id         = "azure-iac-governance-loop"
      action_type      = "loop_stage"
      agent_ref        = ""
      stage_depends_on = ["azure-iac-governance-conform"]
      runbook_refs     = []
      skill_refs       = []
      note             = "Deterministic governance-conform loop gate. No agent."
      action_config = {
        loop_to        = "azure-iac-governance-conform"
        max_iterations = var.max_governance_iterations
        exit_condition = "output_matches_regex"
        # Keep remediating while ok=false (agent patches OPA denies then re-runs).
        # Exit only on ok=true or terminal docs/OPA/generation blockers. Max iterations
        # still advances to azure-pr, which opens with TODOs if residuals remain.
        exit_match = "azure_iac_governance_ok[^\\n]{0,40}\"true\"|stage_summary:azure-iac-governance-conform=blocked:|blocked:governance_docs_unavailable|blocked:governance_opa_unavailable|blocked:governance_evidence_incomplete|blocked:governance_no_progress|blocked:generation_missing"
      }
    },
    {
      stage_id         = "azure-pr"
      action_config    = {}
      agent_ref        = sg_agent.aws_migrator_architect.name
      stage_depends_on = ["azure-iac-loop", "azure-iac-harden", "azure-iac-governance-loop"]
      runbook_refs = [
        sg_runbook_sop.azure_demo_migration_profile.name,
        sg_runbook_sop.aws_migrator_orchestration.name,
      ]
      skill_refs = concat(
        [local.sop_azure_migration_name, local.sop_orchestration_name],
        try(var.workflow_skill_refs["azure-migration-pr::azure-pr"], [])
      )
      note = <<-EOT
        **Fan-in:** waits for `azure-iac-loop` (validate path), `azure-iac-harden`, and `azure-iac-governance-loop` so lint/security autofixes and Nile-conformant HCL are included in the same PR tree. Prefer `azure_iac_governance_ok=true`. If residuals remain after the governance loop, the runner still opens the PR and documents OPA/validator TODOs in `azure/artifacts/TODO.md` + the PR body.
        **Incremental bring-up execution (mandatory):** `create_agent` is allowed (reactree). Put the exact BEGIN/END one-liner in CREATE_AGENT_EXPECTATION (`tool_names` only execute_series), or paste it yourself. ONE `${local.shell_tool_prefix}_execute_series` whose single command is ONLY the shell script between ---BEGIN AZURE_PR_EXECUTE_SERIES--- and ---END AZURE_PR_EXECUTE_SERIES--- below (never use the marker label as the command).
        **Repo contract:** sync `$WORK_ROOT/azure/` to `${trimspace(var.default_iac_repository_url)}` under `azure/`, create a fresh branch starting with `azure/<workflow_run_id>`, and open a new PR against `${trimspace(var.default_branch)}`. If that branch already exists locally/remotely or has any PR history, append a timestamp/PID suffix; never reuse or update an existing PR for a new execution.
        **Hard evidence gate:** read `--- stage_evidence ---` from the execute_series stdout (emitted before the noisy transcript tail). If it contains `azure_pr_url=https://` or `stage_summary:azure-pr=ok`, you MUST `note()` those values and complete successfully — never emit `missing_runner_evidence` when those lines are present. Only emit `stage_summary:azure-pr=blocked:missing_runner_evidence` when neither `azure_pr_url=` / `pr_url=` nor `pr_blocker=` appears in stage_evidence. An explicit `pr_blocker=` is also a conclusive result (note it and return blocked with that reason).
        **Outputs:** note `azure_pr_url`, `pr_url`, `azure_working_branch`, and `stage_summary:azure-pr=ok`.

        ${local.dbsplit_spawn_context_azure_pr}
      EOT
    },
    {
      stage_id         = "azure-only-final"
      action_config    = {}
      agent_ref        = sg_agent.aws_migrator_architect.name
      stage_depends_on = ["azure-pr"]
      runbook_refs = [
        sg_runbook_sop.azure_demo_migration_profile.name,
        sg_runbook_sop.aws_migrator_orchestration.name,
      ]
      skill_refs = concat(
        [local.sop_azure_migration_name, local.sop_orchestration_name],
        try(var.workflow_skill_refs["azure-migration-pr::azure-only-final"], [])
      )
      note = <<-EOT
        **Blocked guards:** if notes or prior stage outputs contain `blocked:azure_source_iac_fetch_failed`, `blocked:remote_runner_shell_unavailable`, `blocked:remote_runner_tofu_missing`, or `stage_summary:azure-pr=blocked:` → `notify` + `stage_summary:azure-only-final=blocked:<reason>` and return. Do **not** treat `stage_summary:azure-iac-validate=blocked:` alone as a final blocker when a non-empty `azure_pr_url` / `pr_url` exists — destination generate is deterministic and the PR documents review-needed.
        **Completion guards:** require evidence that each prior stage concluded. Prefer workflow notes when present; when a note key is absent, accept a prior-stage summary that already carried the same fact (`azure_source_iac_fetched=true`, `azure_migration_blueprint_ok=true`, `azure_iac_generated=true`, a conclusive `azure_iac_validation_ok` of `"true"` or `"false"` / `stage_summary:azure-iac-validate=ok|blocked:…`, `azure_iac_harden_ok=true` / `stage_summary:azure-iac-harden=ok|blocked:…`, a conclusive `azure_iac_governance_ok` of `"true"` or `"false"` / `stage_summary:azure-iac-governance-conform=ok|blocked:…|nonconformant:…`, and a non-empty `azure_pr_url` or `pr_url`). Do **not** block solely because `read_notes` is missing keys that earlier stages already reported in their outputs. Destination generate is deterministic — `validation_ok=false` with an open PR that documents review-needed is a valid finish, not a reason to re-enter generate. When Azure credentials are wired and validation passed, prefer `azure_plan_status` starting with `success` (including `success:sample:N/M`); when validation failed, report plan_status as recorded.
        **Evidence gate:** submit evidence for `azure_source_iac_fetched`, `azure_migration_blueprint_recorded`, `azure_iac_generated`, `azure_iac_validation_evidence`, `azure_iac_harden_evidence`, `azure_iac_governance_evidence`, and `azure_pr_url_recorded` using those facts.
        **Final message:** include source repo/branch, generated group count, validation status, harden autofix/finding counts, governance SHA + conformance, plan status, PR URL, and review-needed artifact path. If governance is false or live plan was skipped for missing credentials, explicitly state the PR is review-candidate/nonconformant or unplanned; do not imply apply readiness. If governance remains false after the bounded remediation loop, record `stage_summary:azure-only-final=blocked:governance_nonconformant` (PR remains open for remediation review), not `ok`.
      EOT
    },
  ]
}

