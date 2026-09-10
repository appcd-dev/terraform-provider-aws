# Per-stage runner context blocks embedded in workflow stage prompts.
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
PREFLIGHT_RUNNER_RULE: create_agent is allowed (reactree). Put the exact BEGIN/END one-liner INSIDE create_agent expectation (same pattern as a successful preflight spawn). tool_names MUST be only ["${local.shell_tool_prefix}_execute_series"]. FIRST tool call: ONE execute_series with commands[0].command set to the BEGIN/END body. Do not invent probes or set -o pipefail.

CREATE_AGENT_EXPECTATION (copy into expectation):
Your FIRST tool call must be ONE ${local.shell_tool_prefix}_execute_series with commands[0].command set to this exact body and no note before it:
${local.runner_capability_preflight_execute_series_body}
After success, note() runner_capability_preflight_ok and stage_summary:runner-capability-preflight.

---BEGIN RUNNER_CAPABILITY_PREFLIGHT_EXECUTE_SERIES---
${local.runner_capability_preflight_execute_series_body}
---END RUNNER_CAPABILITY_PREFLIGHT_EXECUTE_SERIES---
EOT

  aws_migrator_spawn_context_cloud2code = <<-EOT
${local.dbsplit_spawn_context_base}
CLOUD2CODE_RUNNER_RULE: create_agent is allowed (reactree). Mirror preflight: put the exact printf-free pack one-liner INSIDE create_agent expectation. tool_names MUST be only ["${local.shell_tool_prefix}_execute_series"]. Replace AWS_REGION_PLACEHOLDER with the workflow region (e.g. us-east-1) AND replace {{workflow_run_id}} with the real workflow run id from the stagerunner header — never paste the brace token literally (session b2177674). Do not invent set -o pipefail / cloud2code aws scan (sessions 127f2c35 / af38cc9e). On blocked:cloud2code_scan_failed, read cloud2code_log_tail_* from the tool output, fix, and re-run before giving up.

CLOUD2CODE_FILTER_RULE (mandatory): the one-liner starts with CLOUD2CODE_INCLUDE='' CLOUD2CODE_EXCLUDE='' CLOUD2CODE_TAGS=''. These are the ONLY route from the operator query to the scan — the script takes no filter arguments. When the operator supplied cloud2code_include, cloud2code_exclude, or cloud2code_tags, put that comma-separated value inside the matching quotes verbatim (e.g. CLOUD2CODE_INCLUDE='aws_instance'). Leave the empty quotes untouched for keys the operator did not set; empty means full-region scan and the script's default exclude list. Never drop the assignments and never invent filter values the operator did not ask for.

CREATE_AGENT_EXPECTATION (copy into expectation; replace {{workflow_run_id}}, AWS_REGION_PLACEHOLDER, and fill any operator-supplied CLOUD2CODE_* filters):
Your FIRST tool call must be ONE ${local.shell_tool_prefix}_execute_series with commands[0].command set to this exact body and no note before it:
${local.cloud2code_scan_execute_series_body}
After success, note() cloud2code_scan_ok / monolith_state_uri / monolith_resource_count / stage_summary:cloud2code-scan-aws.

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

  dbsplit_spawn_context_azure_governance_conform = <<-EOT
${local.dbsplit_spawn_context_base}

---BEGIN AZURE_GOVERNANCE_CONFORM_EXECUTE_SERIES---
${local.azure_governance_conform_execute_series_body}
---END AZURE_GOVERNANCE_CONFORM_EXECUTE_SERIES---
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

  dbsplit_spawn_context_gcp_governance_conform = <<-EOT
${local.dbsplit_spawn_context_base}

---BEGIN GCP_GOVERNANCE_CONFORM_EXECUTE_SERIES---
${local.gcp_governance_conform_execute_series_body}
---END GCP_GOVERNANCE_CONFORM_EXECUTE_SERIES---
EOT

  dbsplit_spawn_context_gcp_pr = <<-EOT
${local.dbsplit_spawn_context_base}

---BEGIN GCP_PR_EXECUTE_SERIES---
${local.gcp_pr_execute_series_body}
---END GCP_PR_EXECUTE_SERIES---
EOT


  dbsplit_spawn_context = local.dbsplit_spawn_context_base
}
