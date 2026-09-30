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
    GCP blueprint → HCL generate → serial harden → validate → governance-conform → sibling multi-commit GCP PR (`gcp/<run_id>`) with living Nile Priority-1 + OPA evidence (residuals documented in TODO when not yet clear).
    Skips cloud2code, tfstate split, AWS reverse-HCL hydration, and orphan handling.
  EOT
  approve     = true

  # 8 was starving blueprint→governance after source-fetch (empty ~3s stages,
  # skipped:blueprint_missing cascade). Orphan workflow uses 40; GCP needs room
  # for execute_series + discrete note() keys + OPA fix loop per stage.
  metadata = {
    planner_max_tool_iterations = 48
  }

  lifecycle {
    # metadata must apply — do not ignore planner_max_tool_iterations.
    ignore_changes = []
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
    sg_runbook_sop.nile_governance_learn_and_conform.name,
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
      stage_id      = "gcp-source-fetch"
      action_config = {}
      agent_ref     = sg_agent.aws_migrator_architect.name
      runbook_refs = [
        sg_runbook_sop.azure_demo_migration_profile.name,
        sg_runbook_sop.aws_migrator_orchestration.name,
      ]
      skill_refs = concat(
        [local.sop_azure_migration_name, local.sop_orchestration_name],
        try(var.workflow_skill_refs["gcp-migration-pr::gcp-source-fetch"], [])
      )
      note = <<-EOT
        **Purpose:** start from an already-generated AWS IaC split branch instead of rerunning cloud2code/decomposition.
        **Handoff:** prefer workflow input / note `source_pr` (GitHub PR number) → `gh pr view` head branch; else `source_iac_branch` (default `${local.gcp_only_source_branch}`). Optional `source_iac_repository_url` (default `${trimspace(var.default_iac_repository_url)}`).
        **Incremental bring-up execution (mandatory):** `create_agent` is allowed (reactree). Put the exact BEGIN/END one-liner in CREATE_AGENT_EXPECTATION (`tool_names` only execute_series), or paste it yourself. ONE `${local.shell_tool_prefix}_execute_series` with `commands[0].command` set to the **exact character-for-character** one-line body between `---BEGIN GCP_SOURCE_FETCH_EXECUTE_SERIES---` and `---END---` (starts with `SOURCE_PR=`, downloads `pack-entry.sh`, ends with `destination gcp-source-fetch`); set `timeout_seconds=3600` (the 30-second default killed this stage before it started in execution `0ee1ca0b`). If it still returns `signal: killed` or a deadline error, inspect `$WORK_ROOT/.work/logs/gcp-source-fetch.log` and notes, then retry the identical command once; source fetch is idempotent. That body already sets `SOURCE_PR`, `SOURCE_IAC_BRANCH`, `WORKFLOW_RUN_ID`, and `DBSPLIT_EMBEDDED=1`, and fetches the pack when `/opt` lags the module version. **FORBIDDEN (all produce empty runner output):** (1) `command="GCP_SOURCE_FETCH_EXECUTE_SERIES"` (session d6e915ee); (2) `command="... $${GCP_SOURCE_FETCH_EXECUTE_SERIES}"` or any `$`/`$${` expansion of the label (session 93c7dc4d); (3) wrapping the label in env-prefix only; (4) rewriting the one-liner to drop `export` or hardcode an older `/opt/.../script-pack/<ver>` path (session 55e77bfd). **RIGHT:** copy the BEGIN/END body into `commands[0].command` unchanged, except: if user input explicitly has `source_pr=<digits>` or `/pull/<digits>`, set only the `SOURCE_PR='…'` prefix to those digits; if user input has `source_iac_branch=…`, set only `SOURCE_IAC_BRANCH='…'` and keep `SOURCE_PR=''`. Never invent `SOURCE_PR` from examples (session eab54d0d hallucinated `34`).
        **Hard evidence gate:** completion requires a successful runner result with `gcp_source_iac_fetched=true`, `gcp_source_iac_group_count` greater than zero, and runner transcript at `$WORK_ROOT/.work/logs/gcp-source-fetch.log`. Absent those, record `stage_summary:gcp-source-fetch=blocked:missing_runner_evidence` and return blocked — and quote the runner stderr instead of inventing a silent block.
        **Discrete session notes (mandatory):** after a successful runner result you MUST `note()` each of these as its **own key** (not only an evidence blob): `gcp_source_iac_fetched`=`true`, `gcp_source_iac_group_count`=`<N>`, `source_iac_repository_url`, `source_iac_branch`, and `stage_summary:gcp-source-fetch`=`ok`. Downstream stages skip when these keys are missing (session 45b7206d).
        **Outputs:** `$WORK_ROOT/groups`, `$WORK_ROOT/logical_group_manifest.json`, `$WORK_ROOT/source_aws/`, plus the discrete notes above.
        **Forbidden:** cloud2code, tfstate splitting, AWS reverse-HCL hydration, StackGen MCP tools, AppStacks, or asking for the branch path.

        The exact spawn context follows. Put this BEGIN/END body in CREATE_AGENT_EXPECTATION
        (or paste it yourself). Never invent a replacement command:

        ${local.dbsplit_spawn_context_gcp_source_fetch}
      EOT
    },
    {
      stage_id         = "gcp-migration-blueprint"
      action_config    = {}
      agent_ref        = sg_agent.aws_migrator_architect.name
      stage_depends_on = ["gcp-source-fetch"]
      runbook_refs = [
        sg_runbook_sop.azure_demo_migration_profile.name,
        sg_runbook_sop.aws_migrator_orchestration.name,
      ]
      skill_refs = concat(
        [
          local.sop_azure_migration_name,
          local.sop_orchestration_name,
          sg_runbook_sop.destination_iac_wiring_readiness.name,
          sg_runbook_sop.mapping_provider_schema_reasoning.name,
          sg_runbook_sop.mapping_catalog_knowledge.name,
        ],
        try(var.workflow_skill_refs["gcp-migration-pr::gcp-migration-blueprint"], [])
      )
      note = <<-EOT
        **Upstream guard:** skip only when notes clearly show fetch failure (`blocked:gcp_source_iac_fetch_failed` or `stage_summary:gcp-source-fetch=blocked:`). If any note content contains `gcp_source_iac_fetched=true` (including inside `gcp-source-fetch-evidence`), treat upstream as OK and run this stage — do not invent `skipped:source_fetch_failed`.
        **No-approval GCP profile:** use `${local.sop_azure_migration_name}`. Do not call StackGen MCP tools, do not create AppStacks, and do not ask clarifying questions for service choices.
        **Incremental bring-up execution (mandatory):** Your FIRST tool call must be ONE `${local.shell_tool_prefix}_execute_series` with `commands[0].command` set to the **exact character-for-character** one-line body between `---BEGIN GCP_BLUEPRINT_EXECUTE_SERIES---` and `---END---` (starts with `WORKFLOW_RUN_ID=`, downloads `pack-entry.sh`, ends with `destination gcp-migration-blueprint`). **FORBIDDEN:** `command="GCP_BLUEPRINT_EXECUTE_SERIES"` or any `$`/`$${` expansion of the label; do not rewrite the pack path. If the lead agent cannot call the runner tool directly, spawn one subagent whose sole goal is to paste that BEGIN/END body once — never skip the runner.
        **Hard evidence gate:** completion requires a successful runner result with `gcp_migration_blueprint_ok=true` and `gcp_blueprint_group_count` greater than zero. Absent those, record `stage_summary:gcp-migration-blueprint=blocked:missing_runner_evidence` and return blocked.
        **Discrete session notes (mandatory):** `note()` keys `gcp_migration_blueprint_ok`=`true`, `gcp_blueprint_group_count`=`<N>`, `stage_summary:gcp-migration-blueprint`=`ok`.
        **Outputs:** `gcp/artifacts/migration-profile.json`, `gcp/artifacts/migration-blueprint.json`, `gcp/artifacts/review-needed.md`, plus the discrete notes above.

        ${local.dbsplit_spawn_context_gcp_blueprint}
      EOT
    },
    {
      stage_id         = "gcp-iac-generate"
      action_config    = {}
      agent_ref        = sg_agent.aws_migrator_architect.name
      stage_depends_on = ["gcp-migration-blueprint"]
      runbook_refs = [
        sg_runbook_sop.azure_demo_migration_profile.name,
        sg_runbook_sop.aws_migrator_orchestration.name,
      ]
      skill_refs = concat(
        [
          local.sop_azure_migration_name,
          local.sop_orchestration_name,
          sg_runbook_sop.destination_iac_wiring_readiness.name,
          sg_runbook_sop.mapping_provider_schema_reasoning.name,
          sg_runbook_sop.mapping_catalog_knowledge.name,
        ],
        try(var.workflow_skill_refs["gcp-migration-pr::gcp-iac-generate"], [])
      )
      note = <<-EOT
        **Upstream guard:** Prefer notes showing `gcp_migration_blueprint_ok=true` / `stage_summary:gcp-migration-blueprint=ok`. Guild `read_notes` may mask those keys when blueprint/generate overlap on the same runner — do **not** invent `skipped:blueprint_missing` from an incomplete note snapshot. If blueprint already ran this workflow (or workdir `gcp/artifacts/migration-blueprint.json` exists with `group_count` > 0), you MUST run execute_series.
        **Incremental bring-up execution (mandatory):** Your FIRST tool call must be ONE `${local.shell_tool_prefix}_execute_series` pasting the **exact** one-line body between `---BEGIN GCP_GENERATE_EXECUTE_SERIES---` and `---END---` (`pack-entry.sh` … `destination gcp-iac-generate`). **FORBIDDEN:** label-as-command or `$`/`$${` expansion. Spawn a one-shot subagent if needed; never return without runner evidence.
        **Mapping rule:** use the default profile without asking the operator for routine choices, but do not equate a valid scaffold with a completed migration. Follow `destination-iac-wiring-readiness`: trace source instances/attributes/relationships through catalog → resolver → emitted HCL → provider schema; reconcile each source to a destination, explicit fold/non-applicable reason, or documented unresolved decision. A category placeholder is not proof of per-instance wiring. Fix repeatable defects in catalog/generator and add source-state fixtures. Preserve distinctions between evidence, assumptions, and unknowns. Generate HCL only under `$WORK_ROOT/gcp/groups/<group_id>/`.
        **Hard evidence gate:** completion requires a successful runner result with `gcp_iac_generated=true` and `gcp_iac_group_count` greater than zero. Absent those, record `stage_summary:gcp-iac-generate=blocked:missing_runner_evidence` and return blocked.
        **Discrete session notes (mandatory):** `note()` keys `gcp_iac_generated`=`true`, `gcp_iac_group_count`=`<N>`, `stage_summary:gcp-iac-generate`=`ok`.
        **Outputs:** discrete notes above plus `gcp_generation_summary_path`, `gcp_mapping_decisions_path`.

        ${local.dbsplit_spawn_context_gcp_generate}
      EOT
    },
    {
      stage_id      = "gcp-iac-validate"
      action_config = {}
      agent_ref     = sg_agent.aws_migrator_architect.name
      # Serial chain: generate → harden → validate → governance (fan-out was no-op on ai.dev).
      stage_depends_on = ["gcp-iac-harden"]
      runbook_refs = [
        sg_runbook_sop.azure_demo_migration_profile.name,
        sg_runbook_sop.terraform_substate_convergence.name,
        sg_runbook_sop.aws_migrator_orchestration.name,
      ]
      skill_refs = concat(
        [
          local.sop_azure_migration_name,
          local.sop_substate_converge_name,
          local.sop_orchestration_name,
          sg_runbook_sop.destination_iac_wiring_readiness.name,
          sg_runbook_sop.terraform_diagnose_edit_verify.name,
        ],
        try(var.workflow_skill_refs["gcp-migration-pr::gcp-iac-validate"], []),
      )
      note = <<-EOT
        **Upstream guard:** Prefer notes showing `gcp_iac_generated=true` / `stage_summary:gcp-iac-generate=ok`. Guild `read_notes` may mask those keys after busy generate stages — do **not** invent `skipped:generation_missing` from an incomplete note snapshot. If generate already ran this workflow (or workdir `gcp/groups/` exists), you MUST run execute_series; the runner emits `blocked:generation_missing` only when artifacts are truly absent.
        **Incremental bring-up execution (mandatory):** Your FIRST tool call must be ONE `${local.shell_tool_prefix}_execute_series` pasting the **exact** one-line body between `---BEGIN GCP_VALIDATE_EXECUTE_SERIES---` and `---END---` (`pack-entry.sh` … `destination gcp-iac-validate`). **FORBIDDEN:** label-as-command or `$`/`$${` expansion. Set `timeout_seconds=7200`. Spawn a one-shot subagent if needed.
        **Deadline resume:** if execute_series ends with `context deadline exceeded`, `signal: killed`, or incomplete `gcp_iac_validate_progress` without a conclusive `gcp_iac_validation_ok`, **re-paste the identical BEGIN/END body** (validate-groups resume skips finished groups). Do **not** invent `skipped:` from a partial run.
        **Apply-readiness is semantic, not fmt/validate:** run `destination-iac-wiring-readiness` against source state/inventory and generated HCL. Reconcile source instance counts, mapped attributes, settings (including log retention), and dependency edges against generated objects and explicit dispositions. Static validation cannot prove these semantics. Run a live plan when credentials exist; otherwise record `no_live_plan` distinctly and leave apply-readiness unproven. Never run `tofu apply` on migrated GCP resources.
        **Validation contract:** run `tofu fmt`, `tofu validate`, optional `tofu test`, optional `tflint`, and live `tofu plan` (never apply). The pack auto-heals known provider limits (e.g. GCP `name_prefix` ≤37) and retries validate once before reporting `gcp_iac_validation_ok=false`. When `REQUIRE_GCP_LIVE_PLAN=1`, missing credentials fail the stage.
        **Hard evidence gate:** completion requires a successful runner result carrying `gcp_iac_validation_ok` and a non-empty `gcp_iac_validation_report`. Absent those, record `stage_summary:gcp-iac-validate=blocked:missing_runner_evidence` and return blocked.
        **On static fails (remediate until useful):** if `gcp_iac_validation_ok=false` with `static_fail_count>0`, read `gcp/artifacts/validation-report.json` `groups[].validate_error` and `hcl_fix_targets.json` when present. Patch HCL under `gcp/groups/` (add required attrs, fix types, stub vars via `*.auto.tfvars` / `variables.tf` defaults). Prefer source-derived values; if missing, invent a migration assumption and append it to `gcp/artifacts/governance-assumptions.md`. Re-paste the validate BEGIN/END body. Do **not** accept `false` until the validate loop exits (ok=true, terminal blocked, or max iterations). Forbidden: inventing IAM action translations or network redesign.
        **Discrete session notes (mandatory):** `note()` keys `gcp_iac_validation_ok`, `gcp_plan_status`, `gcp_iac_validation_report`, `stage_summary:gcp-iac-validate`.
        **Outputs:** discrete notes above.

        ${local.dbsplit_spawn_context_gcp_validate}
      EOT
    },
    {
      stage_id         = "gcp-iac-harden"
      agent_ref        = sg_agent.aws_migrator_architect.name
      stage_depends_on = ["gcp-iac-generate"]
      action_config    = {}
      runbook_refs = [
        sg_runbook_sop.azure_demo_migration_profile.name,
        sg_runbook_sop.aws_migrator_orchestration.name,
      ]
      skill_refs = concat(
        [
          local.sop_azure_migration_name,
          local.sop_orchestration_name,
          sg_runbook_sop.destination_iac_wiring_readiness.name,
          sg_runbook_sop.terraform_diagnose_edit_verify.name,
        ],
        try(var.workflow_skill_refs["gcp-migration-pr::gcp-iac-harden"], []),
      )
      note = <<-EOT
        **Upstream guard:** Prefer notes showing `gcp_iac_generated=true` / `stage_summary:gcp-iac-generate=ok`. Guild `read_notes` may mask those keys after busy generate stages — do **not** invent `skipped:generation_missing` from an incomplete note snapshot. If generate already ran this workflow (or workdir `gcp/groups/` exists), you MUST run execute_series; the runner emits `blocked:generation_missing` only when artifacts are truly absent.
        **Serial before validate:** runs immediately after generate; validate waits on this stage.
        **Incremental bring-up execution (mandatory):** Your FIRST tool call must be ONE `${local.shell_tool_prefix}_execute_series` pasting the **exact** one-line body between `---BEGIN GCP_HARDEN_EXECUTE_SERIES---` and `---END---` (`pack-entry.sh` … `destination gcp-iac-harden`). **FORBIDDEN:** label-as-command or `$`/`$${` expansion. Set `timeout_seconds=3600`. Spawn a one-shot subagent if needed.
        **Harden contract:** run mechanical autofix (`destination_iac_harden.py`), `tofu fmt`, optional `tflint --fix`, and checkov/tfsec/trivy when installed. Apply fixes under `gcp/groups/` so they ship in the same PR. Do **not** invent IAM translations or network redesigns.
        **Hard evidence gate:** completion requires `gcp_iac_harden_ok=true` and a non-empty `gcp_iac_harden_report`. Absent those, record `stage_summary:gcp-iac-harden=blocked:missing_runner_evidence` and return blocked.
        **Discrete session notes (mandatory):** `note()` keys `gcp_iac_harden_ok`, `gcp_iac_harden_report`, `stage_summary:gcp-iac-harden`=`ok`.
        **Outputs:** discrete notes above plus `gcp_iac_harden_findings`, `gcp_iac_harden_autofix_count`.

        ${local.dbsplit_spawn_context_gcp_harden}
      EOT
    },
    {
      stage_id         = "gcp-iac-governance-conform"
      agent_ref        = sg_agent.aws_migrator_architect.name
      stage_depends_on = ["gcp-iac-validate"]
      action_config    = {}
      runbook_refs = [
        sg_runbook_sop.nile_governance_learn_and_conform.name,
        sg_runbook_sop.azure_demo_migration_profile.name,
        sg_runbook_sop.aws_migrator_orchestration.name,
      ]
      skill_refs = concat(
        [
          local.sop_governance_conform_name,
          local.sop_azure_migration_name,
          local.sop_orchestration_name,
          sg_runbook_sop.rego_plan_reasoning.name,
          sg_runbook_sop.destination_iac_wiring_readiness.name,
          sg_runbook_sop.terraform_diagnose_edit_verify.name,
        ],
        try(var.workflow_skill_refs["gcp-migration-pr::gcp-iac-governance-conform"], [])
      )
      note = <<-EOT
        **Upstream guard:** Prefer notes showing `gcp_iac_generated=true` / `stage_summary:gcp-iac-generate=ok`. Guild `read_notes` may mask those keys after busy generate stages — do **not** invent `skipped:generation_missing` from an incomplete note snapshot. If generate already ran this workflow (or workdir `gcp/groups/` exists), you MUST run OPA governance via execute_series; the runner emits `blocked:generation_missing` only when artifacts are truly absent.
        **Serial after validate:** prior DAG fan-out completed harden/validate/governance in ~1–2s with zero tools (trace e861d081). You MUST call execute_series; never return without OPA runner evidence.
        **Living docs + OPA:** first tool call is ONE `${local.shell_tool_prefix}_execute_series` pasting the **exact** one-line body between `---BEGIN GCP_GOVERNANCE_CONFORM_EXECUTE_SERIES---` and `---END---` (`pack-entry.sh` … `destination gcp-iac-governance-conform`, `timeout_seconds=3600`). **FORBIDDEN:** label-as-command or `$`/`$${` expansion. Harness refreshes Governance-and-Policy, inventories resources, runs OPA, groups repeated plan failures into root-cause `failure_classes`, emits structured Rego-authored remediation guidance; Python never edits generated HCL. Then **continue** (not paste-only): load `${local.sop_governance_conform_name}`, rebuild `gcp/artifacts/governance-decision-tree.json` from **this-run** docs, `${local.shell_tool_prefix}_create_files` the validator (drop `NILE_GOVERNANCE_VALIDATOR_SCAFFOLD`), inspect failure classes and full diagnostics, trace repeated errors to generator/catalog/policy source, make durable source-level corrections with regression tests when authorized, regenerate/fix HCL, and re-run. Apply `destination-iac-wiring-readiness` to verify source-to-destination instances, attributes, relationships, provider schema, and explicit unresolved decisions. Prefer source AWS values; document assumptions in `governance-assumptions.md`. Do not repeat an ineffective edit, invent controls absent from refreshed docs, or interpret missing credentials as a passing plan. Validation evidence is not human approval.
        **Hard evidence gate:** require notes `gcp_iac_governance_ok` (`true` or `false`) plus `gcp_governance_commit_sha` / `gcp/artifacts/governance-source.json`. Docs-unavailable → `blocked:governance_docs_unavailable`. OPA/rules unavailable → `blocked:governance_opa_unavailable`. Nonconformant visits must remediate OPA/validator residuals and re-run until `gcp_iac_governance_ok=true` (loop exits on true or terminal blockers / max iterations). If residuals remain, `gcp-pr` still opens and documents them in `TODO.md` + PR body + assumptions.
        **Discrete session notes (mandatory):** `note()` keys `gcp_iac_governance_ok`, `gcp_iac_governance_report`, `gcp_iac_opa_report` (when present), `gcp_governance_commit_sha`, `stage_summary:gcp-iac-governance-conform`.
        **Outputs:** discrete notes above plus `gcp_iac_opa_fix_hints` when OPA denies.

        ${local.dbsplit_spawn_context_gcp_governance_conform}
      EOT
    },
    {
      stage_id         = "gcp-iac-loop"
      action_type      = "loop_stage"
      agent_ref        = ""
      stage_depends_on = ["gcp-iac-validate"]
      # Clear residuals left when harden/governance were inserted ahead of this slot.
      runbook_refs = []
      skill_refs   = []
      note         = "Deterministic validate remediates loop. No agent."
      action_config = {
        loop_to        = "gcp-iac-validate"
        max_iterations = var.max_validate_iterations
        exit_condition = "output_matches_regex"
        # Remediates until useful: agent patches HCL/vars between visits. Exit on
        # validation_ok=true or terminal blockers only — not on false. Max iters
        # still advances to governance/PR with remarks.
        exit_match = "gcp_iac_validation_ok[^\\n]{0,40}\"true\"|stage_summary:gcp-iac-validate=ok|stage_summary:gcp-iac-validate=blocked:|stage_summary:gcp-source-fetch=blocked:|blocked:gcp_source_iac_fetch_failed|blocked:missing_gcp_credentials|blocked:remote_runner_tofu_missing|blocked:remote_runner_shell_unavailable|GCP_SOURCE_FETCH_EXECUTE_SERIES: not found"
      }
    },
    {
      stage_id         = "gcp-iac-governance-loop"
      action_type      = "loop_stage"
      agent_ref        = ""
      stage_depends_on = ["gcp-iac-governance-conform"]
      runbook_refs     = []
      skill_refs       = []
      note             = "Deterministic governance-conform loop gate. No agent."
      action_config = {
        loop_to        = "gcp-iac-governance-conform"
        max_iterations = var.max_governance_iterations
        exit_condition = "output_matches_regex"
        # Keep remediating while ok=false (agent patches OPA denies then re-runs).
        # Exit only on ok=true or terminal docs/OPA/generation blockers. Max iterations
        # still advances to gcp-pr, which opens with TODOs if residuals remain.
        exit_match = "gcp_iac_governance_ok[^\\n]{0,40}\"true\"|stage_summary:gcp-iac-governance-conform=blocked:|blocked:governance_docs_unavailable|blocked:governance_opa_unavailable|blocked:governance_evidence_incomplete|blocked:governance_no_progress|blocked:generation_missing"
      }
    },
    {
      stage_id         = "gcp-pr"
      action_config    = {}
      agent_ref        = sg_agent.aws_migrator_architect.name
      stage_depends_on = ["gcp-iac-loop", "gcp-iac-harden", "gcp-iac-governance-loop"]
      runbook_refs = [
        sg_runbook_sop.azure_demo_migration_profile.name,
        sg_runbook_sop.aws_migrator_orchestration.name,
      ]
      skill_refs = concat(
        [
          local.sop_azure_migration_name,
          local.sop_orchestration_name,
          sg_runbook_sop.aws_discovery_pr_review.name,
          sg_runbook_sop.destination_iac_wiring_readiness.name,
        ],
        try(var.workflow_skill_refs["gcp-migration-pr::gcp-pr"], [])
      )
      note = <<-EOT
        **Fan-in:** waits for `gcp-iac-loop` (validate path), `gcp-iac-harden`, and `gcp-iac-governance-loop` so lint/security autofixes and Nile-conformant HCL are included in the same PR tree. Prefer `gcp_iac_governance_ok=true`. If residuals remain after the governance loop, the runner still opens the PR and documents OPA/validator TODOs in `gcp/artifacts/TODO.md` + the PR body.
        **Incremental bring-up execution (mandatory):** `create_agent` is allowed (reactree). Put the exact BEGIN/END one-liner in CREATE_AGENT_EXPECTATION (`tool_names` only execute_series), or paste it yourself. ONE `${local.shell_tool_prefix}_execute_series` whose single command is the ONE-LINE body between BEGIN/END GCP_PR_EXECUTE_SERIES (`pack-entry.sh` … `destination gcp-pr`); set `timeout_seconds=3600` (the 30-second default killed this runner before it started in execution `0ee1ca0b`). Never pass the marker name as the command. On `signal: killed` / deadline errors, inspect the stage log and check the repository for an already-created branch/PR for this workflow run before retrying, because PR creation has side effects; retry the identical command once only when no branch or PR was created.
        **Repo contract:** sync `$WORK_ROOT/gcp/` to `${trimspace(var.default_iac_repository_url)}` under `gcp/`, create a fresh branch starting with `gcp/<workflow_run_id>`, and open a new PR against `${trimspace(var.default_branch)}`. If that branch already exists locally/remotely or has any PR history, append a timestamp/PID suffix; never reuse or update an existing PR for a new execution.
        **Hard evidence gate:** read `--- stage_evidence ---` from the execute_series stdout (emitted before the noisy transcript tail). If it contains `gcp_pr_url=https://` or `stage_summary:gcp-pr=ok`, you MUST `note()` those values and complete successfully — never emit `missing_runner_evidence` when those lines are present. Only emit `stage_summary:gcp-pr=blocked:missing_runner_evidence` when neither `gcp_pr_url=` / `pr_url=` nor `pr_blocker=` appears in stage_evidence. An explicit `pr_blocker=` is also a conclusive result (note it and return blocked with that reason).
        **Outputs:** note `gcp_pr_url`, `pr_url`, `gcp_working_branch`, and `stage_summary:gcp-pr=ok` (or the pr_blocker summary).

        ${local.dbsplit_spawn_context_gcp_pr}
      EOT
    },
    {
      stage_id         = "gcp-only-final"
      action_config    = {}
      agent_ref        = sg_agent.aws_migrator_architect.name
      stage_depends_on = ["gcp-pr"]
      runbook_refs = [
        sg_runbook_sop.azure_demo_migration_profile.name,
        sg_runbook_sop.aws_migrator_orchestration.name,
      ]
      skill_refs = concat(
        [
          local.sop_azure_migration_name,
          local.sop_orchestration_name,
          sg_runbook_sop.aws_discovery_pr_review.name,
        ],
        try(var.workflow_skill_refs["gcp-migration-pr::gcp-only-final"], [])
      )
      note = <<-EOT
        **Blocked guards:** if notes or prior stage outputs contain `blocked:gcp_source_iac_fetch_failed`, `blocked:remote_runner_shell_unavailable`, `blocked:remote_runner_tofu_missing`, or `stage_summary:gcp-pr=blocked:` → `notify` + `stage_summary:gcp-only-final=blocked:<reason>` and return. Do **not** treat `stage_summary:gcp-iac-validate=blocked:` alone as a final blocker when a non-empty `gcp_pr_url` / `pr_url` exists — destination generate is deterministic and the PR documents review-needed.
        **Completion guards:** require evidence that each prior stage concluded. Prefer workflow notes when present; when a note key is absent, accept a prior-stage summary that already carried the same fact (`gcp_source_iac_fetched=true`, `gcp_migration_blueprint_ok=true`, `gcp_iac_generated=true`, a conclusive `gcp_iac_validation_ok` of `"true"` or `"false"` / `stage_summary:gcp-iac-validate=ok|blocked:…`, `gcp_iac_harden_ok=true` / `stage_summary:gcp-iac-harden=ok|blocked:…`, a conclusive `gcp_iac_governance_ok` of `"true"` or `"false"` / `stage_summary:gcp-iac-governance-conform=ok|blocked:…|nonconformant:…`, and a non-empty `gcp_pr_url` or `pr_url`). Do **not** block solely because `read_notes` is missing keys that earlier stages already reported in their outputs. Destination generate is deterministic — `validation_ok=false` with an open PR that documents review-needed is a valid finish, not a reason to re-enter generate. When GCP credentials are wired and validation passed, prefer `gcp_plan_status` starting with `success` (including `success:sample:N/M`); when validation failed, report plan_status as recorded.
        **Evidence gate:** submit evidence for `gcp_source_iac_fetched`, `gcp_migration_blueprint_recorded`, `gcp_iac_generated`, `gcp_iac_validation_evidence`, `gcp_iac_harden_evidence`, `gcp_iac_governance_evidence`, and `gcp_pr_url_recorded` using those facts.
        **Final message:** include source repo/branch, generated group count, validation status, harden autofix/finding counts, governance SHA + conformance, plan status, PR URL, and review-needed artifact path. If governance is false or live plan was skipped for missing credentials, explicitly state the PR is review-candidate/nonconformant or unplanned; do not imply apply readiness. If governance remains false after the bounded remediation loop, record `stage_summary:gcp-only-final=blocked:governance_nonconformant` (PR remains open for remediation review), not `ok`.
      EOT
    },
  ]
}

