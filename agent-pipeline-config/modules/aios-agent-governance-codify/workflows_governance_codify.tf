resource "sg_workflow" "governance_rules_codify" {
  name        = local.workflow_name
  domain      = "governance"
  description = <<-EOT
    On-demand workflow: read governance markdown from Governance-and-Policy (source),
    codify Rego + conftest into rules/ on Nile-Factory (target), open a PR on the target repo,
    and gate on target-repo GitHub Actions (rules-validate). GitHub integration only — no remote runner.
  EOT
  approve     = true

  metadata = {
    planner_max_tool_iterations = var.planner_max_tool_iterations
  }

  lifecycle {
    ignore_changes = [
      metadata,
    ]
  }

  required_inputs = []
  optional_inputs = [
    "source_repository_url",
    "source_ref",
    "target_repository_url",
    "target_ref",
    "base_branch",
    "rules_output_dir",
    "force_recodify",
  ]
  evidence_checklist_ref = sg_evidence_checklist.governance_rules_codify_evidence.name

  example_queries = [
    "Codify Governance-and-Policy markdown into Nile-Factory rules/ and open a PR",
    "Refresh Rego rule packs for stale governance docs at main",
  ]

  triggers = [
    {
      field  = "intent"
      values = ["governance-rules-codify"]
      type   = "passive"
    },
  ]

  runbook_refs = [
    sg_runbook_sop.governance_rules_codify.name,
  ]

  stages = [
    for stage in local.governance_codify_stages : {
      stage_id    = stage.stage_id
      description = stage.description
      note        = stage.note
      required    = stage.required
    }
  ]

  stage_bindings = [
    {
      stage_id         = "rules-intake"
      action_config    = {}
      action_type      = ""
      parallel_agents  = []
      stage_depends_on = []
      agent_ref        = sg_agent.governance_codify_architect.name
      runbook_refs = [
        sg_runbook_sop.governance_rules_codify.name,
      ]
      skill_refs = concat(
        [local.sop_governance_codify_name],
        try(var.workflow_skill_refs["governance-rules-codify::rules-intake"], []),
      )
      note = <<-EOT
        Intake only — mechanical inventory. You are NOT writing Rego in this stage.

        FIRST tool call: ONE ${local.github_tool_prefix}_execute_series (copy verbatim):
        ${local.codify_intake_execute_series_template}

        On success note:
        - codify_source_clone_dir=${local.source_clone_dir}, codify_source_repo_full=${local.default_source_repo_full}
        - codify_clone_dir=${local.target_clone_dir}, codify_repo_full=${local.default_target_repo_full}

        Glob governance/**/*.md on SOURCE. Read rules/manifest.json on TARGET.
        note(codify_inventory_json=<nile-codify-inventory/v1>) once from script output — do not overwrite with placeholders.

        STOP when inventory is noted. Do NOT spawn sub-agents for codify or PR — stagerunner runs rules-codify and rules-pr next.
        Fail closed: blocked:codify_source_unavailable only if clone fails.
      EOT
    },
    {
      stage_id         = "rules-codify"
      action_config    = {}
      action_type      = ""
      parallel_agents  = []
      agent_ref        = sg_agent.governance_codify_architect.name
      stage_depends_on = ["rules-intake"]
      runbook_refs     = [sg_runbook_sop.governance_rules_codify.name]
      skill_refs = concat(
        [local.sop_governance_codify_name, local.opa_codify_method_name],
        try(var.workflow_skill_refs["governance-rules-codify::rules-codify"], []),
      )
      note = <<-EOT
        You are the OPA/Rego coordinator. read_notes + load_skill(${local.opa_codify_method_name}) first.

        GitHub sidecar /tmp is NOT durable across stages. FIRST tool call — re-sync clones (copy verbatim, same as intake):
        ${local.codify_intake_execute_series_template}

        Parse codify_inventory_json. Parent-only: bootstrap when bootstrap_needed=true, then branch:
        ONE ${local.github_tool_prefix}_execute_series (replace SOURCE_COMMIT_SHA with full source_commit_sha from inventory):
        ${local.codify_branch_execute_series_template}
        Branch pattern: {source_commit_sha}_{YYYYMMDDHHMMSS} (UTC timestamp — unique per run). note(codify_branch=<from stdout>).

        PARALLEL CODIFY (mandatory when stale_docs has 2+ entries):
        - Do NOT spawn one mega sub-agent for all packs.
        - Sequence: (1) bootstrap/branch sub-agent and WAIT for result, (2) YOU spawn create_agent once per stale doc in ONE response with background=false.
        - WAIT for every pack-worker TOOL_CALL_RESULT before merging manifest. Do not start rules-pr logic.
        - Each pack worker MUST write IaC Rego (input.resource_changes) for enforce:true. FORBIDDEN process schemas.
        - Each pack with policy.rego MUST pass: opa test <pack_dir>. Wrong test syntax: count(data.policy.deny with input as x). Right: count(deny) == 0 with input as x.
        - trim() always needs cutset: trim(s, " \\t\\n\\r"). Never trim(s).
        - Prefer tagging-labeling-standard with azurerm_/google_ resource_changes fixtures.
        - Process-only docs: controls.json enforce:false only.
        - ALWAYS write rules/run-tests.sh + .github/workflows/rules-validate.yml if missing (bootstrap verbatim from method skill).
        - After merge: bash ${local.target_clone_dir}/rules/run-tests.sh must exit 0 before handoff.
        - Budget per pack worker: max_tool_iterations=32, max_llm_calls=40, timeout_seconds>=900.
        - Parent: merge manifest from completed codify_pack_* notes only, commit on ${local.target_clone_dir}.

        When force_recodify=true: treat all docs as stale and overwrite packs.

        MANDATORY before stage ends — push branch to origin (substitute CODIFY_BRANCH with codify_branch from notes):
        ONE ${local.github_tool_prefix}_execute_series working_dir=${local.target_clone_dir}:
        ${local.codify_push_execute_series_template}

        Never delegate rules-pr. End with note(codify_rules_written=true), note(codify_branch_pushed=true), and note(codify_handoff_json=...).
      EOT
    },
    {
      stage_id         = "rules-pr"
      action_config    = {}
      action_type      = ""
      parallel_agents  = []
      agent_ref        = sg_agent.governance_codify_architect.name
      stage_depends_on = ["rules-codify"]
      runbook_refs     = [sg_runbook_sop.governance_rules_codify.name]
      skill_refs = concat(
        [local.sop_governance_codify_name],
        try(var.workflow_skill_refs["governance-rules-codify::rules-pr"], []),
      )
      note = <<-EOT
        read_notes + workflow_notes_snapshot. PR only — no Rego authoring in this stage.

        PR repo: TARGET ${local.default_target_repo_full}. Clone dir ${local.target_clone_dir}.
        Use codify_branch from notes (pattern {source_commit_sha}_{YYYYMMDDHHMMSS}). If branch has 0 commits ahead of base, fail closed with blocked:codify_pr_failed — do not open empty PR.

        GitHub sidecar /tmp is NOT durable across stages. FIRST — checkout codify_branch from origin (replace CODIFY_BRANCH in command with codify_branch from notes):
        ONE ${local.github_tool_prefix}_execute_series:
        ${local.codify_checkout_branch_execute_series_template}

        PREFLIGHT before push:
        1) Ensure ${local.target_clone_dir}/rules/run-tests.sh and ${local.target_clone_dir}/.github/workflows/rules-validate.yml exist (write bootstrap if missing, commit).
        2) bash ${local.target_clone_dir}/rules/run-tests.sh must exit 0. If red → blocked:codify_tests_failed (do not open PR).

        THEN: ONE ${local.github_tool_prefix}_execute_series (working_dir=${local.target_clone_dir}, timeout_seconds=600):
        ${local.codify_pr_execute_series_template}
        Substitute {{BRANCH}} with codify_branch from notes. note(rules_pr_url=<from gh stdout>).

        Poll gh pr checks until "${var.github_check_name}" green → note(rules_codify_ok=true). Do NOT merge.
      EOT
    },
  ]
}
