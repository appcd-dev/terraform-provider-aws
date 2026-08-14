# Per-stage create_agent contracts (Guild StageBinding.spawn_contracts).
# Runtime resolves {{workflow_run_id}}, {{work_root}}, and {{stage_note_var:NAME}} from binding notes.

locals {
  dbsplit_spawn_context_base = <<-EOT
workflow_run_id: {{workflow_run_id}}
WORK_ROOT: ${local.runner_work_home}/.{{workflow_run_id}}
ABS_WORK_ROOT: ${local.runner_work_home}/.{{workflow_run_id}}
runner_work_home: ${local.runner_work_home}
remote_runner_name: ${local.resolved_remote_runner_name}
shell_tool_prefix: ${local.shell_tool_prefix}
DBSPLIT_ALLOCATE_SHA256: ${local.script_pack_allocate_sha256}
DBSPLIT_DECOMPOSER_SHA256: ${local.script_pack_decomposer_sha256}
script_pack_version: ${local.script_pack_version}
script_pack_git_ref: ${local.script_pack_git_ref}
EOT

  aws_migrator_spawn_context_preflight = <<-EOT
${local.dbsplit_spawn_context_base}
PREFLIGHT_RUNNER_RULE: make ONE ${local.shell_tool_prefix}_execute_series call pasting RUNNER_CAPABILITY_PREFLIGHT_EXECUTE_SERIES verbatim. Do not call note before execute_series. Do not call execute_command. Do not author custom probes. After success, note() runner_capability_preflight_ok and stage_summary:runner-capability-preflight.

---BEGIN RUNNER_CAPABILITY_PREFLIGHT_EXECUTE_SERIES---
${local.runner_capability_preflight_execute_series_body}
---END RUNNER_CAPABILITY_PREFLIGHT_EXECUTE_SERIES---
EOT

  aws_migrator_spawn_context_cloud2code = <<-EOT
${local.dbsplit_spawn_context_base}
CLOUD2CODE_RUNNER_RULE: read_notes once, then make ONE ${local.shell_tool_prefix}_execute_series call containing exactly two commands: (1) write ${local.runner_work_home}/.{{workflow_run_id}}/.work/cloud2code-inputs.json from the notes; (2) paste CLOUD2CODE_SCAN_EXECUTE_SERIES verbatim. Do not call note before execute_series. Do not call execute_command. Do not run cloud2code on the lead agent. Do not author availability probes, installers, or scan commands: the pasted bootstrap checks for cloud2code and installs pinned v0.5.1 into $HOME/.local/bin when absent, then forces cloud2code --auto-import=false. Do not ask for monolith_state_uri.

---BEGIN CLOUD2CODE_SCAN_EXECUTE_SERIES---
${local.cloud2code_scan_execute_series_body}
---END CLOUD2CODE_SCAN_EXECUTE_SERIES---
EOT

  dbsplit_spawn_context_ingest = <<-EOT
${local.dbsplit_spawn_context_base}
INGEST_RUNNER_RULE: read_notes once. Shell tools ONLY: ${local.shell_tool_prefix}_execute_command — NEVER ${local.resolved_github_integration_name}_* or ${local.resolved_aws_integration_name}_* (MCP integrations, not the remote runner; trace 019e905a51fc). Tool order: exactly ONE execute_command (working_dir=/, timeout_seconds=${local.subagent_budgets.script_runner_timeout_seconds}): paste INGEST_BOOTSTRAP_EXECUTE_COMMAND verbatim. Do NOT pre-write .work/spawn_monolith_uri and do NOT compose any shell yourself — execute_command runs under /bin/sh (dash), where `set -o pipefail` and nested single quotes abort in ~1 ms (trace 28f93699); the bootstrap already resolves WORK_ROOT from WORKFLOW_RUN_ID and MONOLITH_URI from ${local.runner_work_home}/.{{workflow_run_id}}/notes.json — it runs raw ${local.script_pack_preload_dir}/ingest-bootstrap.sh, then copies the large script pack from ${local.script_pack_preload_dir}; do NOT use create_files; do NOT paste heredoc or LLM-authored shell. Handoff MUST include script_pack_version ${local.script_pack_version}.

INGEST_BOOTSTRAP_SHA256: ${local.ingest_bootstrap_sha256}

INGEST_BOOTSTRAP_EXECUTE_COMMAND:
${local.ingest_bootstrap_execute_command}
EOT

  dbsplit_spawn_context_registry = <<-EOT
${local.dbsplit_spawn_context_base}

---BEGIN IAC_PR_EXECUTE_SERIES---
${local.iac_pr_execute_series_body}
---END IAC_PR_EXECUTE_SERIES---
EOT

  dbsplit_spawn_context_converge = <<-EOT
${local.dbsplit_spawn_context_base}

---BEGIN CONVERGE_EXECUTE_SERIES---
${local.converge_execute_series_body}
---END CONVERGE_EXECUTE_SERIES---
EOT

  dbsplit_spawn_context_azure_source_fetch = <<-EOT
${local.dbsplit_spawn_context_base}
default_source_iac_repository_url: ${trimspace(var.default_iac_repository_url)}
default_source_iac_branch: ${local.azure_only_source_branch}

---BEGIN AZURE_SOURCE_FETCH_EXECUTE_SERIES---
${local.azure_source_fetch_execute_series_body}
---END AZURE_SOURCE_FETCH_EXECUTE_SERIES---
EOT

  dbsplit_spawn_context_azure_current_run_source_fetch = <<-EOT
${local.dbsplit_spawn_context_base}
default_source_iac_repository_url: ${trimspace(var.default_iac_repository_url)}
default_source_iac_branch: ${local.azure_current_run_source_branch}

---BEGIN AZURE_SOURCE_FETCH_EXECUTE_SERIES---
${local.azure_current_run_source_fetch_execute_series_body}
---END AZURE_SOURCE_FETCH_EXECUTE_SERIES---
EOT

  dbsplit_spawn_context_azure_blueprint = <<-EOT
${local.dbsplit_spawn_context_base}

---BEGIN AZURE_BLUEPRINT_EXECUTE_SERIES---
${local.azure_blueprint_execute_series_body}
---END AZURE_BLUEPRINT_EXECUTE_SERIES---
EOT

  dbsplit_spawn_context_azure_generate = <<-EOT
${local.dbsplit_spawn_context_base}

---BEGIN AZURE_GENERATE_EXECUTE_SERIES---
${local.azure_generate_execute_series_body}
---END AZURE_GENERATE_EXECUTE_SERIES---
EOT

  dbsplit_spawn_context_azure_validate = <<-EOT
${local.dbsplit_spawn_context_base}

---BEGIN AZURE_VALIDATE_EXECUTE_SERIES---
${local.azure_validate_execute_series_body}
---END AZURE_VALIDATE_EXECUTE_SERIES---
EOT

  dbsplit_spawn_context_azure_harden = <<-EOT
${local.dbsplit_spawn_context_base}

---BEGIN AZURE_HARDEN_EXECUTE_SERIES---
${local.azure_harden_execute_series_body}
---END AZURE_HARDEN_EXECUTE_SERIES---
EOT

  dbsplit_spawn_context_azure_pr = <<-EOT
${local.dbsplit_spawn_context_base}

---BEGIN AZURE_PR_EXECUTE_SERIES---
${local.azure_pr_execute_series_body}
---END AZURE_PR_EXECUTE_SERIES---
EOT


  dbsplit_spawn_context_gcp_source_fetch = <<-EOT
${local.dbsplit_spawn_context_base}
default_source_iac_repository_url: ${trimspace(var.default_iac_repository_url)}
default_source_iac_branch: ${local.gcp_only_source_branch}

---BEGIN GCP_SOURCE_FETCH_EXECUTE_SERIES---
${local.gcp_source_fetch_execute_series_body}
---END GCP_SOURCE_FETCH_EXECUTE_SERIES---
EOT

  dbsplit_spawn_context_gcp_current_run_source_fetch = <<-EOT
${local.dbsplit_spawn_context_base}
default_source_iac_repository_url: ${trimspace(var.default_iac_repository_url)}
default_source_iac_branch: ${local.azure_current_run_source_branch}

---BEGIN GCP_SOURCE_FETCH_EXECUTE_SERIES---
${local.gcp_current_run_source_fetch_execute_series_body}
---END GCP_SOURCE_FETCH_EXECUTE_SERIES---
EOT

  dbsplit_spawn_context_gcp_blueprint = <<-EOT
${local.dbsplit_spawn_context_base}

---BEGIN GCP_BLUEPRINT_EXECUTE_SERIES---
${local.gcp_blueprint_execute_series_body}
---END GCP_BLUEPRINT_EXECUTE_SERIES---
EOT

  dbsplit_spawn_context_gcp_generate = <<-EOT
${local.dbsplit_spawn_context_base}

---BEGIN GCP_GENERATE_EXECUTE_SERIES---
${local.gcp_generate_execute_series_body}
---END GCP_GENERATE_EXECUTE_SERIES---
EOT

  dbsplit_spawn_context_gcp_validate = <<-EOT
${local.dbsplit_spawn_context_base}

---BEGIN GCP_VALIDATE_EXECUTE_SERIES---
${local.gcp_validate_execute_series_body}
---END GCP_VALIDATE_EXECUTE_SERIES---
EOT

  dbsplit_spawn_context_gcp_harden = <<-EOT
${local.dbsplit_spawn_context_base}

---BEGIN GCP_HARDEN_EXECUTE_SERIES---
${local.gcp_harden_execute_series_body}
---END GCP_HARDEN_EXECUTE_SERIES---
EOT

  dbsplit_spawn_context_gcp_pr = <<-EOT
${local.dbsplit_spawn_context_base}

---BEGIN GCP_PR_EXECUTE_SERIES---
${local.gcp_pr_execute_series_body}
---END GCP_PR_EXECUTE_SERIES---
EOT


  dbsplit_spawn_context = local.dbsplit_spawn_context_base

  spawn_contracts_runner_capability_preflight = [
    {
      sub_agent_name = "runner-capability-preflight-runner"
      task_type      = var.subagent_task_type
      tool_names = [
        "${local.shell_tool_prefix}_execute_series",
        "note",
        "read_notes",
      ]
      max_llm_calls       = local.subagent_budgets.script_runner_max_llm_calls
      max_tool_iterations = local.subagent_budgets.script_runner_max_tool_iterations
      timeout_seconds     = 600
      goal                = "make ONE ${local.shell_tool_prefix}_execute_series call pasting RUNNER_CAPABILITY_PREFLIGHT_EXECUTE_SERIES verbatim. After success, note() runner_capability_preflight_ok and stage_summary:runner-capability-preflight. Forbidden: custom probes, installers, or asking the operator for credentials mid-preflight."
      context             = local.aws_migrator_spawn_context_preflight
    },
  ]

  spawn_contracts_cloud2code_scan = [
    {
      sub_agent_name = "cloud2code-scan-runner"
      task_type      = var.subagent_task_type
      tool_names = [
        "${local.shell_tool_prefix}_execute_series",
        "note",
        "read_notes",
      ]
      max_llm_calls       = local.subagent_budgets.script_runner_max_llm_calls
      max_tool_iterations = local.subagent_budgets.script_runner_max_tool_iterations
      timeout_seconds     = local.subagent_budgets.script_runner_timeout_seconds
      goal                = "read_notes once. Then make ONE ${local.shell_tool_prefix}_execute_series call with exactly two commands: first write .work/cloud2code-inputs.json from those notes; second paste CLOUD2CODE_SCAN_EXECUTE_SERIES verbatim without replacing any part. Do not call note before execute_series and do not call execute_command. The bootstrap installs pinned cloud2code into $HOME/.local/bin only when absent. After execute_series succeeds, note() cloud2code_scan_ok, cloud2code_tfstate_path, monolith_state_uri, monolith_resource_count, and stage_summary:cloud2code-scan-aws. Forbidden: custom probes, custom installers, custom scan commands, or asking for monolith_state_uri."
      context             = local.aws_migrator_spawn_context_cloud2code
    },
  ]

  spawn_contracts_ingest_and_split = [
    {
      sub_agent_name = "ingest-and-split-runner"
      task_type      = var.subagent_task_type
      tool_names = [
        "${local.shell_tool_prefix}_execute_command",
        "note",
        "read_notes",
      ]
      max_llm_calls       = local.subagent_budgets.script_runner_max_llm_calls
      max_tool_iterations = local.subagent_budgets.script_runner_max_tool_iterations
      timeout_seconds     = local.subagent_budgets.script_runner_timeout_seconds
      goal                = "read_notes once. Shell: ONLY ${local.shell_tool_prefix}_execute_command — never github/aws MCP tools. Exactly ONE execute_command: paste INGEST_BOOTSTRAP_EXECUTE_COMMAND from context verbatim (timeout_seconds=${local.subagent_budgets.script_runner_timeout_seconds}, working_dir=/); it runs ${local.script_pack_preload_dir}/ingest-bootstrap.sh, which resolves WORK_ROOT and MONOLITH_URI itself from ${local.runner_work_home}/.{{workflow_run_id}}/notes.json. Forbidden: pre-writing .work/spawn_monolith_uri, create_files, heredoc, LLM-authored bootstrap, custom goals — execute_command runs under dash, so composed shell with `set -o pipefail` or nested single quotes dies in ~1 ms (trace 28f93699). After bootstrap: cat .work/ingest-handoff.txt and note() handoff keys. Retry: THIS goal verbatim."
      context             = local.dbsplit_spawn_context_ingest
    },
  ]

  spawn_contracts_registry_codegen = [
    {
      sub_agent_name = "registry-and-import-codegen-runner"
      task_type      = var.subagent_task_type
      tool_names = [
        "${local.shell_tool_prefix}_execute_command",
        "${local.shell_tool_prefix}_execute_series",
        "note",
        "read_notes",
      ]
      max_llm_calls       = local.subagent_budgets.registry_codegen_max_llm_calls
      max_tool_iterations = local.subagent_budgets.registry_codegen_max_tool_iterations
      timeout_seconds     = 1800
      goal                = "read_notes iac_repository_url default_branch count_reconciliation_ok. ONE execute_series: paste IAC_PR_EXECUTE_SERIES verbatim (iac-pr-pipeline includes prepare-parallel-artifacts). After execute_series: note() pr_url, batch_payloads_path, large_state_sample_group_ids, groups_synced_to_repo. Forbidden: inline python, create_files, *-probe."
      context             = local.dbsplit_spawn_context_registry
    },
  ]

  spawn_contracts_shell_converge = [
    {
      sub_agent_name = "shell-converge-matrix-runner"
      task_type      = var.subagent_task_type
      tool_names = [
        "${local.shell_tool_prefix}_execute_command",
        "${local.shell_tool_prefix}_execute_series",
        "note",
        "read_notes",
      ]
      max_llm_calls       = local.subagent_budgets.registry_codegen_max_llm_calls
      max_tool_iterations = local.subagent_budgets.registry_codegen_max_tool_iterations
      timeout_seconds     = 1800
      goal                = "ONE execute_series: paste CONVERGE_EXECUTE_SERIES verbatim (hydrate-and-plan-matrix). The script self-repairs Terraform init/provider-cache disk failures and records init logs. After execute_series: note() multi_plan_zero_diff_ok and hydrate_ok_groups from stdout. Mirror hcl_hydration_status and hcl_init_status keys from notes.json to note(). If create_agent dedup blocks this runner on a loop retry, report dedup to the architect; the architect may run the exact same CONVERGE_EXECUTE_SERIES directly. Forbidden: hcl-hydrate-runner-batch, *-probe."
      context             = local.dbsplit_spawn_context_converge
    },
  ]

  spawn_contracts_azure_source_fetch = [
    {
      sub_agent_name = "azure-source-fetch-runner"
      task_type      = var.subagent_task_type
      tool_names = [
        "${local.shell_tool_prefix}_execute_command",
        "${local.shell_tool_prefix}_execute_series",
        "note",
        "read_notes",
      ]
      max_llm_calls       = local.subagent_budgets.registry_codegen_max_llm_calls
      max_tool_iterations = local.subagent_budgets.registry_codegen_max_tool_iterations
      timeout_seconds     = 1800
      goal                = "ONE execute_series: paste AZURE_SOURCE_FETCH_EXECUTE_SERIES verbatim. It clones ${trimspace(var.default_iac_repository_url)} branch ${local.azure_only_source_branch}, copies aws/groups and aws/artifacts into WORK_ROOT, then note() azure_source_iac_fetched, azure_source_iac_group_count, source_iac_repository_url, source_iac_branch, and stage_summary:azure-source-fetch. Forbidden: cloud2code, tfstate splitting, StackGen MCP tools, AppStacks."
      context             = local.dbsplit_spawn_context_azure_source_fetch
    },
  ]

  spawn_contracts_azure_current_run_source_fetch = [
    {
      sub_agent_name = "azure-source-fetch-runner"
      task_type      = var.subagent_task_type
      tool_names = [
        "${local.shell_tool_prefix}_execute_command",
        "${local.shell_tool_prefix}_execute_series",
        "note",
        "read_notes",
      ]
      max_llm_calls       = local.subagent_budgets.registry_codegen_max_llm_calls
      max_tool_iterations = local.subagent_budgets.registry_codegen_max_tool_iterations
      timeout_seconds     = 1800
      goal                = "ONE execute_series: paste AZURE_SOURCE_FETCH_EXECUTE_SERIES verbatim. It clones the same AWS IaC branch produced earlier in this workflow (read notes iac_push_branch/working_branch, fallback split/{{workflow_run_id}}), copies aws/groups and aws/artifacts into WORK_ROOT, then note() azure_source_iac_fetched, azure_source_iac_group_count, source_iac_repository_url, source_iac_branch, and stage_summary:azure-source-fetch. Forbidden: cloud2code, tfstate splitting, StackGen MCP tools, AppStacks."
      context             = local.dbsplit_spawn_context_azure_current_run_source_fetch
    },
  ]

  spawn_contracts_azure_blueprint = [
    {
      sub_agent_name = "azure-migration-blueprint-runner"
      task_type      = var.subagent_task_type
      tool_names = [
        "${local.shell_tool_prefix}_execute_command",
        "${local.shell_tool_prefix}_execute_series",
        "note",
        "read_notes",
      ]
      max_llm_calls       = local.subagent_budgets.registry_codegen_max_llm_calls
      max_tool_iterations = local.subagent_budgets.registry_codegen_max_tool_iterations
      timeout_seconds     = 1800
      goal                = "ONE execute_series: paste AZURE_BLUEPRINT_EXECUTE_SERIES verbatim. After execute_series: note() azure_migration_blueprint_ok, azure_blueprint_group_count, azure_migration_blueprint_path, azure_review_needed_path, and stage_summary:azure-migration-blueprint. Forbidden: StackGen MCP tools, AppStacks, ask_clarifying_question for mappings, inline authoring."
      context             = local.dbsplit_spawn_context_azure_blueprint
    },
  ]

  spawn_contracts_azure_only_blueprint = [
    {
      sub_agent_name = "azure-only-blueprint-runner"
      task_type      = var.subagent_task_type
      tool_names = [
        "${local.shell_tool_prefix}_execute_command",
        "${local.shell_tool_prefix}_execute_series",
        "note",
        "read_notes",
      ]
      max_llm_calls       = local.subagent_budgets.registry_codegen_max_llm_calls
      max_tool_iterations = local.subagent_budgets.registry_codegen_max_tool_iterations
      timeout_seconds     = 1800
      goal                = "ONE execute_series: paste AZURE_BLUEPRINT_EXECUTE_SERIES verbatim. After execute_series: note() azure_migration_blueprint_ok, azure_blueprint_group_count, azure_migration_blueprint_path, azure_review_needed_path, and stage_summary:azure-migration-blueprint. Forbidden: StackGen MCP tools, AppStacks, ask_clarifying_question for mappings, inline authoring."
      context             = local.dbsplit_spawn_context_azure_blueprint
    },
  ]

  spawn_contracts_azure_generate = [
    {
      sub_agent_name = "azure-iac-generate-runner"
      task_type      = var.subagent_task_type
      tool_names = [
        "${local.shell_tool_prefix}_execute_command",
        "${local.shell_tool_prefix}_execute_series",
        "note",
        "read_notes",
      ]
      max_llm_calls       = local.subagent_budgets.registry_codegen_max_llm_calls
      max_tool_iterations = local.subagent_budgets.registry_codegen_max_tool_iterations
      timeout_seconds     = 1800
      goal                = "ONE execute_series: paste AZURE_GENERATE_EXECUTE_SERIES verbatim. After execute_series: note() azure_iac_generated, azure_iac_group_count, azure_generation_summary_path, azure_mapping_decisions_path, and stage_summary:azure-iac-generate. Forbidden: StackGen MCP tools, AppStacks, ask_clarifying_question for mappings."
      context             = local.dbsplit_spawn_context_azure_generate
    },
  ]

  spawn_contracts_azure_only_generate = [
    {
      sub_agent_name = "azure-only-generate-runner"
      task_type      = var.subagent_task_type
      tool_names = [
        "${local.shell_tool_prefix}_execute_command",
        "${local.shell_tool_prefix}_execute_series",
        "note",
        "read_notes",
      ]
      max_llm_calls       = local.subagent_budgets.registry_codegen_max_llm_calls
      max_tool_iterations = local.subagent_budgets.registry_codegen_max_tool_iterations
      timeout_seconds     = 1800
      goal                = "ONE execute_series: paste AZURE_GENERATE_EXECUTE_SERIES verbatim. After execute_series: note() azure_iac_generated, azure_iac_group_count, azure_generation_summary_path, azure_mapping_decisions_path, and stage_summary:azure-iac-generate. Forbidden: StackGen MCP tools, AppStacks, ask_clarifying_question for mappings."
      context             = local.dbsplit_spawn_context_azure_generate
    },
  ]

  spawn_contracts_azure_validate = [
    {
      sub_agent_name = "azure-iac-validate-runner"
      task_type      = var.subagent_task_type
      tool_names = [
        "${local.shell_tool_prefix}_execute_command",
        "${local.shell_tool_prefix}_execute_series",
        "note",
        "read_notes",
      ]
      max_llm_calls       = local.subagent_budgets.registry_codegen_max_llm_calls
      max_tool_iterations = local.subagent_budgets.registry_codegen_max_tool_iterations
      timeout_seconds     = 7200
      goal                = "ONE execute_series: paste AZURE_VALIDATE_EXECUTE_SERIES verbatim with timeout_seconds=7200 (live Azure plan across many groups is slow). After execute_series: note() azure_iac_validation_ok, azure_plan_status, azure_iac_validation_report, and stage_summary:azure-iac-validate. When REQUIRE_AZURE_LIVE_PLAN=1, missing credentials fail validate; otherwise soft-skip is allowed. Forbidden: manual fixes outside azure/groups."
      context             = local.dbsplit_spawn_context_azure_validate
    },
  ]

  spawn_contracts_azure_only_validate = [
    {
      sub_agent_name = "azure-only-validate-runner"
      task_type      = var.subagent_task_type
      tool_names = [
        "${local.shell_tool_prefix}_execute_command",
        "${local.shell_tool_prefix}_execute_series",
        "note",
        "read_notes",
      ]
      max_llm_calls       = local.subagent_budgets.registry_codegen_max_llm_calls
      max_tool_iterations = local.subagent_budgets.registry_codegen_max_tool_iterations
      timeout_seconds     = 7200
      goal                = "ONE execute_series: paste AZURE_VALIDATE_EXECUTE_SERIES verbatim with timeout_seconds=7200 (live Azure plan across many groups is slow). After execute_series: note() azure_iac_validation_ok, azure_plan_status, azure_iac_validation_report, and stage_summary:azure-iac-validate. When REQUIRE_AZURE_LIVE_PLAN=1, missing credentials fail validate; otherwise soft-skip is allowed. Forbidden: manual fixes outside azure/groups."
      context             = local.dbsplit_spawn_context_azure_validate
    },
  ]

  spawn_contracts_azure_only_harden = [
    {
      sub_agent_name = "azure-only-harden-runner"
      task_type      = var.subagent_task_type
      tool_names = [
        "${local.shell_tool_prefix}_execute_command",
        "${local.shell_tool_prefix}_execute_series",
        "note",
        "read_notes",
      ]
      max_llm_calls       = local.subagent_budgets.registry_codegen_max_llm_calls
      max_tool_iterations = local.subagent_budgets.registry_codegen_max_tool_iterations
      timeout_seconds     = 3600
      goal                = "ONE execute_series: paste AZURE_HARDEN_EXECUTE_SERIES verbatim with timeout_seconds=3600. After execute_series: note() azure_iac_harden_ok, azure_iac_harden_report, azure_iac_harden_findings, azure_iac_harden_autofix_count, and stage_summary:azure-iac-harden. Parallel with validate — do not wait for plan. Forbidden: inventing IAM/network redesigns."
      context             = local.dbsplit_spawn_context_azure_harden
    },
  ]

  spawn_contracts_azure_pr = [
    {
      sub_agent_name = "azure-pr-runner"
      task_type      = var.subagent_task_type
      tool_names = [
        "${local.shell_tool_prefix}_execute_command",
        "${local.shell_tool_prefix}_execute_series",
        "note",
        "read_notes",
      ]
      max_llm_calls       = local.subagent_budgets.registry_codegen_max_llm_calls
      max_tool_iterations = local.subagent_budgets.registry_codegen_max_tool_iterations
      timeout_seconds     = 1800
      goal                = "ONE execute_series: paste AZURE_PR_EXECUTE_SERIES verbatim. After execute_series: read --- stage_evidence --- first; if azure_pr_url=https:// or stage_summary:azure-pr=ok is present, note() azure_pr_url, pr_url, azure_working_branch, stage_summary:azure-pr=ok and succeed — never emit missing_runner_evidence when those lines exist. Branch must be azure/<workflow_run_id>; sync only the generated azure/ tree and artifacts. Forbidden: StackGen MCP tools or AppStack creation."
      context             = local.dbsplit_spawn_context_azure_pr
    },
  ]

  spawn_contracts_azure_only_pr = [
    {
      sub_agent_name = "azure-only-pr-runner"
      task_type      = var.subagent_task_type
      tool_names = [
        "${local.shell_tool_prefix}_execute_command",
        "${local.shell_tool_prefix}_execute_series",
        "note",
        "read_notes",
      ]
      max_llm_calls       = local.subagent_budgets.registry_codegen_max_llm_calls
      max_tool_iterations = local.subagent_budgets.registry_codegen_max_tool_iterations
      timeout_seconds     = 1800
      goal                = "ONE execute_series: paste AZURE_PR_EXECUTE_SERIES verbatim. After execute_series: read --- stage_evidence --- first; if azure_pr_url=https:// or stage_summary:azure-pr=ok is present, note() azure_pr_url, pr_url, azure_working_branch, stage_summary:azure-pr=ok and succeed — never emit missing_runner_evidence when those lines exist. Branch must be azure/<workflow_run_id>; sync only the generated azure/ tree and artifacts. Forbidden: StackGen MCP tools or AppStack creation."
      context             = local.dbsplit_spawn_context_azure_pr
    },
  ]
  spawn_contracts_gcp_source_fetch = [
    {
      sub_agent_name = "gcp-source-fetch-runner"
      task_type      = var.subagent_task_type
      tool_names = [
        "${local.shell_tool_prefix}_execute_command",
        "${local.shell_tool_prefix}_execute_series",
        "note",
        "read_notes",
      ]
      max_llm_calls       = local.subagent_budgets.registry_codegen_max_llm_calls
      max_tool_iterations = local.subagent_budgets.registry_codegen_max_tool_iterations
      timeout_seconds     = 1800
      goal                = "ONE execute_series: paste the ONE-LINE body between BEGIN/END GCP_SOURCE_FETCH_EXECUTE_SERIES (starts with SOURCE_PR= … run-destination-stage.sh gcp-source-fetch). WRONG: command=GCP_SOURCE_FETCH_EXECUTE_SERIES. Required edit: SOURCE_PR='<digits>' from prompt (e.g. 34). Then note() gcp_source_iac_fetched, gcp_source_iac_group_count, source_iac_branch, stage_summary:gcp-source-fetch. Forbidden: cloud2code, tfstate splitting, StackGen MCP, AppStacks."
      context             = local.dbsplit_spawn_context_gcp_source_fetch
    },
  ]

  spawn_contracts_gcp_current_run_source_fetch = [
    {
      sub_agent_name = "gcp-source-fetch-runner"
      task_type      = var.subagent_task_type
      tool_names = [
        "${local.shell_tool_prefix}_execute_command",
        "${local.shell_tool_prefix}_execute_series",
        "note",
        "read_notes",
      ]
      max_llm_calls       = local.subagent_budgets.registry_codegen_max_llm_calls
      max_tool_iterations = local.subagent_budgets.registry_codegen_max_tool_iterations
      timeout_seconds     = 1800
      goal                = "ONE execute_series: paste the ONE-LINE body between BEGIN/END GCP_SOURCE_FETCH_EXECUTE_SERIES (starts with SOURCE_PR= … run-destination-stage.sh gcp-source-fetch). WRONG: command=GCP_SOURCE_FETCH_EXECUTE_SERIES. Required edit: SOURCE_PR='<digits>' from prompt (e.g. 34). Then note() gcp_source_iac_fetched, gcp_source_iac_group_count, source_iac_branch, stage_summary:gcp-source-fetch. Forbidden: cloud2code, tfstate splitting, StackGen MCP, AppStacks."
      context             = local.dbsplit_spawn_context_gcp_current_run_source_fetch
    },
  ]

  spawn_contracts_gcp_blueprint = [
    {
      sub_agent_name = "gcp-migration-blueprint-runner"
      task_type      = var.subagent_task_type
      tool_names = [
        "${local.shell_tool_prefix}_execute_command",
        "${local.shell_tool_prefix}_execute_series",
        "note",
        "read_notes",
      ]
      max_llm_calls       = local.subagent_budgets.registry_codegen_max_llm_calls
      max_tool_iterations = local.subagent_budgets.registry_codegen_max_tool_iterations
      timeout_seconds     = 1800
      goal                = "ONE execute_series: paste GCP_BLUEPRINT_EXECUTE_SERIES verbatim. After execute_series: note() gcp_migration_blueprint_ok, gcp_blueprint_group_count, gcp_migration_blueprint_path, gcp_review_needed_path, and stage_summary:gcp-migration-blueprint. Forbidden: StackGen MCP tools, AppStacks, ask_clarifying_question for mappings, inline authoring."
      context             = local.dbsplit_spawn_context_gcp_blueprint
    },
  ]

  spawn_contracts_gcp_only_blueprint = [
    {
      sub_agent_name = "gcp-only-blueprint-runner"
      task_type      = var.subagent_task_type
      tool_names = [
        "${local.shell_tool_prefix}_execute_command",
        "${local.shell_tool_prefix}_execute_series",
        "note",
        "read_notes",
      ]
      max_llm_calls       = local.subagent_budgets.registry_codegen_max_llm_calls
      max_tool_iterations = local.subagent_budgets.registry_codegen_max_tool_iterations
      timeout_seconds     = 1800
      goal                = "ONE execute_series: paste GCP_BLUEPRINT_EXECUTE_SERIES verbatim. After execute_series: note() gcp_migration_blueprint_ok, gcp_blueprint_group_count, gcp_migration_blueprint_path, gcp_review_needed_path, and stage_summary:gcp-migration-blueprint. Forbidden: StackGen MCP tools, AppStacks, ask_clarifying_question for mappings, inline authoring."
      context             = local.dbsplit_spawn_context_gcp_blueprint
    },
  ]

  spawn_contracts_gcp_generate = [
    {
      sub_agent_name = "gcp-iac-generate-runner"
      task_type      = var.subagent_task_type
      tool_names = [
        "${local.shell_tool_prefix}_execute_command",
        "${local.shell_tool_prefix}_execute_series",
        "note",
        "read_notes",
      ]
      max_llm_calls       = local.subagent_budgets.registry_codegen_max_llm_calls
      max_tool_iterations = local.subagent_budgets.registry_codegen_max_tool_iterations
      timeout_seconds     = 1800
      goal                = "ONE execute_series: paste GCP_GENERATE_EXECUTE_SERIES verbatim. After execute_series: note() gcp_iac_generated, gcp_iac_group_count, gcp_generation_summary_path, gcp_mapping_decisions_path, and stage_summary:gcp-iac-generate. Forbidden: StackGen MCP tools, AppStacks, ask_clarifying_question for mappings."
      context             = local.dbsplit_spawn_context_gcp_generate
    },
  ]

  spawn_contracts_gcp_only_generate = [
    {
      sub_agent_name = "gcp-only-generate-runner"
      task_type      = var.subagent_task_type
      tool_names = [
        "${local.shell_tool_prefix}_execute_command",
        "${local.shell_tool_prefix}_execute_series",
        "note",
        "read_notes",
      ]
      max_llm_calls       = local.subagent_budgets.registry_codegen_max_llm_calls
      max_tool_iterations = local.subagent_budgets.registry_codegen_max_tool_iterations
      timeout_seconds     = 1800
      goal                = "ONE execute_series: paste GCP_GENERATE_EXECUTE_SERIES verbatim. After execute_series: note() gcp_iac_generated, gcp_iac_group_count, gcp_generation_summary_path, gcp_mapping_decisions_path, and stage_summary:gcp-iac-generate. Forbidden: StackGen MCP tools, AppStacks, ask_clarifying_question for mappings."
      context             = local.dbsplit_spawn_context_gcp_generate
    },
  ]

  spawn_contracts_gcp_validate = [
    {
      sub_agent_name = "gcp-iac-validate-runner"
      task_type      = var.subagent_task_type
      tool_names = [
        "${local.shell_tool_prefix}_execute_command",
        "${local.shell_tool_prefix}_execute_series",
        "note",
        "read_notes",
      ]
      max_llm_calls       = local.subagent_budgets.registry_codegen_max_llm_calls
      max_tool_iterations = local.subagent_budgets.registry_codegen_max_tool_iterations
      timeout_seconds     = 7200
      goal                = "ONE execute_series: paste GCP_VALIDATE_EXECUTE_SERIES verbatim with timeout_seconds=7200 (live GCP plan across many groups is slow). After execute_series: note() gcp_iac_validation_ok, gcp_plan_status, gcp_iac_validation_report, and stage_summary:gcp-iac-validate. When REQUIRE_GCP_LIVE_PLAN=1, missing credentials fail validate; otherwise soft-skip is allowed. Forbidden: manual fixes outside gcp/groups."
      context             = local.dbsplit_spawn_context_gcp_validate
    },
  ]

  spawn_contracts_gcp_only_validate = [
    {
      sub_agent_name = "gcp-only-validate-runner"
      task_type      = var.subagent_task_type
      tool_names = [
        "${local.shell_tool_prefix}_execute_command",
        "${local.shell_tool_prefix}_execute_series",
        "note",
        "read_notes",
      ]
      max_llm_calls       = local.subagent_budgets.registry_codegen_max_llm_calls
      max_tool_iterations = local.subagent_budgets.registry_codegen_max_tool_iterations
      timeout_seconds     = 7200
      goal                = "ONE execute_series: paste GCP_VALIDATE_EXECUTE_SERIES verbatim with timeout_seconds=7200 (live GCP plan across many groups is slow). After execute_series: note() gcp_iac_validation_ok, gcp_plan_status, gcp_iac_validation_report, and stage_summary:gcp-iac-validate. When REQUIRE_GCP_LIVE_PLAN=1, missing credentials fail validate; otherwise soft-skip is allowed. Forbidden: manual fixes outside gcp/groups."
      context             = local.dbsplit_spawn_context_gcp_validate
    },
  ]

  spawn_contracts_gcp_only_harden = [
    {
      sub_agent_name = "gcp-only-harden-runner"
      task_type      = var.subagent_task_type
      tool_names = [
        "${local.shell_tool_prefix}_execute_command",
        "${local.shell_tool_prefix}_execute_series",
        "note",
        "read_notes",
      ]
      max_llm_calls       = local.subagent_budgets.registry_codegen_max_llm_calls
      max_tool_iterations = local.subagent_budgets.registry_codegen_max_tool_iterations
      timeout_seconds     = 3600
      goal                = "ONE execute_series: paste the ONE-LINE body between BEGIN/END GCP_HARDEN_EXECUTE_SERIES (run-destination-stage.sh gcp-iac-harden) with timeout_seconds=3600. After execute_series: note() gcp_iac_harden_ok, gcp_iac_harden_report, gcp_iac_harden_findings, gcp_iac_harden_autofix_count, and stage_summary:gcp-iac-harden. Parallel with validate — do not wait for plan. Forbidden: inventing IAM/network redesigns."
      context             = local.dbsplit_spawn_context_gcp_harden
    },
  ]

  spawn_contracts_gcp_pr = [
    {
      sub_agent_name = "gcp-pr-runner"
      task_type      = var.subagent_task_type
      tool_names = [
        "${local.shell_tool_prefix}_execute_command",
        "${local.shell_tool_prefix}_execute_series",
        "note",
        "read_notes",
      ]
      max_llm_calls       = local.subagent_budgets.registry_codegen_max_llm_calls
      max_tool_iterations = local.subagent_budgets.registry_codegen_max_tool_iterations
      timeout_seconds     = 1800
      goal                = "ONE execute_series: paste GCP_PR_EXECUTE_SERIES verbatim. After execute_series: read --- stage_evidence --- first; if gcp_pr_url=https:// or stage_summary:gcp-pr=ok is present, note() gcp_pr_url, pr_url, gcp_working_branch, stage_summary:gcp-pr=ok and succeed — never emit missing_runner_evidence when those lines exist. Branch must be gcp/<workflow_run_id>; sync only the generated gcp/ tree and artifacts. Forbidden: StackGen MCP tools or AppStack creation."
      context             = local.dbsplit_spawn_context_gcp_pr
    },
  ]

  spawn_contracts_gcp_only_pr = [
    {
      sub_agent_name = "gcp-only-pr-runner"
      task_type      = var.subagent_task_type
      tool_names = [
        "${local.shell_tool_prefix}_execute_command",
        "${local.shell_tool_prefix}_execute_series",
        "note",
        "read_notes",
      ]
      max_llm_calls       = local.subagent_budgets.registry_codegen_max_llm_calls
      max_tool_iterations = local.subagent_budgets.registry_codegen_max_tool_iterations
      timeout_seconds     = 1800
      goal                = "ONE execute_series: paste GCP_PR_EXECUTE_SERIES verbatim. After execute_series: read --- stage_evidence --- first; if gcp_pr_url=https:// or stage_summary:gcp-pr=ok is present, note() gcp_pr_url, pr_url, gcp_working_branch, stage_summary:gcp-pr=ok and succeed — never emit missing_runner_evidence when those lines exist. Branch must be gcp/<workflow_run_id>; sync only the generated gcp/ tree and artifacts. Forbidden: StackGen MCP tools or AppStack creation."
      context             = local.dbsplit_spawn_context_gcp_pr
    },
  ]
}
