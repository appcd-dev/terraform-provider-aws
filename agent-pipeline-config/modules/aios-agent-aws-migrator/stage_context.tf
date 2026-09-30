# Per-stage runner context blocks embedded in workflow stage prompts.
# Runtime resolves {{workflow_run_id}}, {{work_root}}, and {{stage_note_var:NAME}} from binding notes.
# Keep each block to: base keys, substitutions, one BEGIN/END command. No policy essays.

locals {
  dbsplit_spawn_context_base = <<-EOT
workflow_run_id: {{workflow_run_id}}
WORK_ROOT: ${local.runner_work_home}/.{{workflow_run_id}}
ABS_WORK_ROOT: ${local.runner_work_home}/.{{workflow_run_id}}
runner_work_home: ${local.runner_work_home}
remote_runner_name: ${local.resolved_remote_runner_name}
shell_tool_prefix: ${local.shell_tool_prefix}
script_pack_version: ${local.script_pack_version}
script_pack_preload_dir: ${local.script_pack_preload_dir}
EOT

  aws_migrator_spawn_context_preflight = <<-EOT
${local.dbsplit_spawn_context_base}
substitute: {{workflow_run_id}} → real id from the stagerunner header
working_dir: omit or /
timeout_seconds: ${local.subagent_budgets.script_runner_timeout_seconds}

---BEGIN RUNNER_CAPABILITY_PREFLIGHT_EXECUTE_SERIES---
${local.runner_capability_preflight_execute_series_body}
---END RUNNER_CAPABILITY_PREFLIGHT_EXECUTE_SERIES---
EOT

  aws_migrator_spawn_context_cloud2code = <<-EOT
${local.dbsplit_spawn_context_base}
substitute: AWS_REGION_PLACEHOLDER → region; CLOUD2CODE_EXCLUDE_PLACEHOLDER → comma-separated requested aws_* resource types (or empty); {{workflow_run_id}} → real id
working_dir: omit or /
timeout_seconds: ${local.subagent_budgets.script_runner_timeout_seconds}

---BEGIN CLOUD2CODE_SCAN_EXECUTE_SERIES---
${local.cloud2code_scan_execute_series_body}
---END CLOUD2CODE_SCAN_EXECUTE_SERIES---
EOT

  dbsplit_spawn_context_ingest = <<-EOT
${local.dbsplit_spawn_context_base}
DBSPLIT_ALLOCATE_SHA256: ${local.script_pack_allocate_sha256}
DBSPLIT_DECOMPOSER_SHA256: ${local.script_pack_decomposer_sha256}
INGEST_BOOTSTRAP_SHA256: ${local.ingest_bootstrap_sha256}
working_dir: /
timeout_seconds: ${local.subagent_budgets.script_runner_timeout_seconds}

---BEGIN INGEST_BOOTSTRAP_EXECUTE_COMMAND---
${local.ingest_bootstrap_execute_command}
---END INGEST_BOOTSTRAP_EXECUTE_COMMAND---
EOT

  dbsplit_spawn_context_registry = <<-EOT
${local.dbsplit_spawn_context_base}
timeout_seconds: ${local.subagent_budgets.script_runner_timeout_seconds}

---BEGIN IAC_PR_EXECUTE_SERIES---
${local.iac_pr_execute_series_body}
---END IAC_PR_EXECUTE_SERIES---
EOT

  dbsplit_spawn_context_converge = <<-EOT
${local.dbsplit_spawn_context_base}
timeout_seconds: ${local.subagent_budgets.script_runner_timeout_seconds}

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
timeout_seconds: ${local.subagent_budgets.script_runner_timeout_seconds}

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
timeout_seconds: ${local.subagent_budgets.script_runner_timeout_seconds}

---BEGIN GCP_PR_EXECUTE_SERIES---
${local.gcp_pr_execute_series_body}
---END GCP_PR_EXECUTE_SERIES---
EOT

  dbsplit_spawn_context = local.dbsplit_spawn_context_base
}
