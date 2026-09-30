terraform {
  required_version = ">= 1.5"
  required_providers {
    sg = {
      source = "releases.stackgen.com/stackgen/stackgen"
      # sg_remote_runner create + install commands (>= 0.1.23); spawn_contracts (>= 0.1.21).
      version = ">= 0.1.39, < 0.2.0"
    }
  }
}

locals {
  module_prefix = "aws-migrator"

  # Normalize name_suffix: empty → "" (no suffix), non-empty → "-<suffix>"
  suffix = trimspace(var.name_suffix) == "" ? "" : "-${trimspace(var.name_suffix)}"

  agent_name = "aws-migrator-architect${local.suffix}"

  workflow_primary_name    = "aws-cloud-discovery${local.suffix}"
  workflow_azure_only_name = "azure-migration-pr${local.suffix}"
  workflow_gcp_only_name   = "gcp-migration-pr${local.suffix}"
  workflow_secondary_name  = "aws-migrator-orphan-iac-module-authoring${local.suffix}"
  webhook_name             = "github-aws-migrator-receiver${local.suffix}"

  sop_cloud2code_scan_name           = "cloud2code-aws-region-scan-sop${local.suffix}"
  sop_discovery_stage_contract_name  = "aws-cloud-discovery-stage-contract-sop${local.suffix}"
  sop_orchestration_name             = "aws-migrator-orchestration-sop${local.suffix}"
  sop_shard_extraction_name          = "aws-migrator-terraform-state-shard-extraction-sop${local.suffix}"
  sop_tfstate_splitter_name          = "aws-migrator-tfstate-splitter-sop${local.suffix}"
  sop_registry_reverse_name          = "aws-migrator-terraform-registry-reverse-iac-sop${local.suffix}"
  sop_substate_converge_name         = "aws-migrator-terraform-substate-convergence-sop${local.suffix}"
  sop_azure_migration_name           = "aws-migrator-azure-migration-profile-sop${local.suffix}"
  sop_governance_conform_name        = "nile-governance-learn-and-conform-sop${local.suffix}"
  sop_orphan_bootstrap_name          = "aws-migrator-orphan-iac-module-bootstrap-sop${local.suffix}"
  sop_cce_iac_alignment              = "aws-migrator-cce-iac-alignment-sop${local.suffix}"
  evidence_primary_name              = "aws-cloud-discovery-evidence${local.suffix}"
  evidence_azure_only_name           = "azure-migration-pr-evidence${local.suffix}"
  evidence_gcp_only_name             = "gcp-migration-pr-evidence${local.suffix}"
  evidence_orphan_name               = "aws-migrator-orphan-iac-module-authoring-evidence${local.suffix}"
  aws_discovery_pr_review_skill_name = "aws-discovery-pr-review${local.suffix}"
  terraform_diagnose_skill_name      = "terraform-diagnose-edit-verify${local.suffix}"
  rego_plan_reasoning_skill_name     = "rego-plan-reasoning${local.suffix}"
  mapping_provider_schema_skill_name = "mapping-provider-schema-reasoning${local.suffix}"
  mapping_catalog_knowledge_name     = "aws-migrator-mapping-catalog-reference${local.suffix}"
  destination_iac_wiring_skill_name  = "destination-iac-wiring-readiness${local.suffix}"
  # Destination PR workflows fetch prior discovery IaC from these branches (deployment-supplied fallback).
  azure_only_source_branch        = trimspace(var.azure_only_source_branch)
  gcp_only_source_branch          = trimspace(var.gcp_only_source_branch)
  azure_current_run_source_branch = "discovery/{{workflow_run_id}}"

  # Cloud integration names (MCP tool prefixes). Kept independent of the agent
  # product name so the same AWS/GitHub integrations can be reused by other agents.
  github_integration_name = "cloud-github${local.suffix}"
  aws_integration_name    = "cloud-aws${local.suffix}"

  default_remote_runner_name  = "${local.module_prefix}-runner${local.suffix}"
  resolved_remote_runner_name = trimspace(var.remote_runner_name) != "" ? trimspace(var.remote_runner_name) : local.default_remote_runner_name
  # Guild exposes runner shell tools as `<runner_name>_execute_command|series|parallel|create_files`.
  shell_tool_prefix = local.resolved_remote_runner_name
  runner_work_home  = trimspace(var.runner_work_home) != "" ? trimspace(var.runner_work_home) : "/home/runner"

  # `provision_*` must be plan-time known because it drives `count` on the
  # nested integration modules. We deliberately do NOT inspect
  # `var.*_secret_id` here — the consumer often wires those from another
  # module's output (`module.github_pat[0].secret_id`,
  # `module.aws_integration[0].secret_id`) which is only known at apply time.
  # When `existing_*_integration_name` is empty we always try to provision; the
  # inner integration module's preconditions surface a clear error if the
  # secret input is also missing.
  provision_github = trimspace(var.existing_github_integration_name) == ""
  provision_aws    = trimspace(var.existing_aws_integration_name) == ""

  resolved_github_integration_name = trimspace(var.existing_github_integration_name) != "" ? var.existing_github_integration_name : (
    local.provision_github ? module.github_integration[0].integration_name : ""
  )
  resolved_aws_integration_name = trimspace(var.existing_aws_integration_name) != "" ? var.existing_aws_integration_name : (
    local.provision_aws ? module.aws_integration[0].integration_name : ""
  )
  resolved_azure_integration_name = trimspace(var.existing_azure_integration_name)
  resolved_gcp_integration_name   = trimspace(var.existing_gcp_integration_name)

  # Runner mothership sync: vault metadata must be flat env keys (GIT_TOKEN, AWS_ACCESS_KEY_ID, ARM_*, …).
  # Create vault secrets whenever inline creds are set — including customer-managed runners
  # (create_remote_runner=false). Gating AWS on create_remote_runner left Walmart with git
  # sync only and empty AWS_* on nile-runner (session 1db33f6a cloud2code IMDS failure).
  create_runner_git_env_secret = trimspace(var.runner_git_token) != ""
  create_runner_aws_env_secret = (
    trimspace(var.runner_aws_access_key_id) != "" && trimspace(var.runner_aws_secret_access_key) != ""
  )

  runner_git_env_secret_id   = local.create_runner_git_env_secret ? sg_secret.runner_git_env[0].id : trimspace(var.runner_git_env_secret_id)
  runner_aws_env_secret_id   = local.create_runner_aws_env_secret ? sg_secret.runner_aws_env[0].id : trimspace(var.runner_aws_env_secret_id)
  runner_azure_env_secret_id = trimspace(var.runner_azure_env_secret_id)
  runner_gcp_env_secret_id   = trimspace(var.runner_gcp_env_secret_id)

  script_pack_tarball_url = trimspace(var.script_pack_tarball_url) != "" ? trimspace(var.script_pack_tarball_url) : "https://github.com/${trimspace(var.script_pack_release_repo)}/releases/download/pack-${local.script_pack_version}/script-pack-${local.script_pack_version}.tar.gz"

  create_runner_script_pack_env_secret = var.remote_runner_script_pack_sync_enabled && trimspace(var.runner_script_pack_env_secret_id) == ""
  runner_script_pack_env_secret_id     = local.create_runner_script_pack_env_secret ? sg_secret.runner_script_pack[0].id : trimspace(var.runner_script_pack_env_secret_id)

  runner_generic_secret_ref_ids_base = distinct(concat(
    var.remote_runner_generic_secret_ref_ids,
    trimspace(local.runner_script_pack_env_secret_id) != "" ? [local.runner_script_pack_env_secret_id] : [],
  ))

  # PR+review bar: require live plan when Azure is wired unless explicitly overridden.
  require_azure_live_plan = var.require_azure_live_plan != null ? var.require_azure_live_plan : (
    local.runner_azure_env_secret_id != "" || local.resolved_azure_integration_name != ""
  )
  require_gcp_live_plan = var.require_gcp_live_plan != null ? var.require_gcp_live_plan : (
    local.runner_gcp_env_secret_id != "" || local.resolved_gcp_integration_name != ""
  )

  runner_typed_secret_refs_base = merge(
    trimspace(local.runner_git_env_secret_id) != "" ? { github = local.runner_git_env_secret_id } : {},
    trimspace(local.runner_aws_env_secret_id) != "" ? { aws = local.runner_aws_env_secret_id } : {},
    trimspace(local.runner_azure_env_secret_id) != "" ? { azure = local.runner_azure_env_secret_id } : {},
    trimspace(local.runner_gcp_env_secret_id) != "" ? { gcp = local.runner_gcp_env_secret_id } : {},
    var.remote_runner_typed_secret_refs,
  )
  runner_typed_secret_refs      = var.remote_runner_secret_sync_enabled ? local.runner_typed_secret_refs_base : {}
  runner_generic_secret_ref_ids = var.remote_runner_secret_sync_enabled ? local.runner_generic_secret_ref_ids_base : []
  # Keep this plan-time known: do not inspect sg_secret.*.id (unknown until apply),
  # or count on sg_remote_runner_secrets fails with "Invalid count argument".
  runner_secrets_sync_configured = var.remote_runner_secret_sync_enabled && (
    trimspace(var.runner_git_token) != ""
    || trimspace(var.runner_git_env_secret_id) != ""
    || trimspace(var.runner_aws_access_key_id) != "" && trimspace(var.runner_aws_secret_access_key) != ""
    || trimspace(var.runner_aws_env_secret_id) != ""
    || trimspace(var.runner_azure_env_secret_id) != ""
    || trimspace(var.runner_gcp_env_secret_id) != ""
    || local.create_runner_script_pack_env_secret
    || trimspace(var.runner_script_pack_env_secret_id) != ""
    || length(var.remote_runner_typed_secret_refs) > 0
    || length(var.remote_runner_generic_secret_ref_ids) > 0
  )

  integration_shell_tool_names = [
    "create_files",
    "execute_command",
    "execute_parallel",
    "execute_series",
    "test_connection",
  ]
  auto_approve_all_available_tools = distinct(concat(
    [
      for tool_name in local.integration_shell_tool_names :
      "${trimspace(local.resolved_github_integration_name)}_${tool_name}"
    ],
    [
      "note",
      "read_notes",
    ],
    [
      for tool_name in local.integration_shell_tool_names :
      "${trimspace(local.resolved_aws_integration_name)}_${tool_name}"
    ],
    [
      for tool_name in local.integration_shell_tool_names :
      "${local.shell_tool_prefix}_${tool_name}"
    ],
    [
      "web_search",
    ],
  ))

  stage_runner_script          = trimspace(file("${path.module}/scripts/stage-runner.sh"))
  allocate_manifest_script     = file("${path.module}/scripts/allocate_manifest.py")
  tfstate_monolith_decomposer  = file("${path.module}/scripts/tfstate_monolith_decomposer.py")
  azure_mapping_catalog_script = file("${path.module}/scripts/azure_mapping_catalog.py")
  azure_mapping_catalog_json   = file("${path.module}/mappings/aws-to-azure.json")
  gcp_mapping_catalog_script   = file("${path.module}/scripts/gcp_mapping_catalog.py")
  gcp_mapping_catalog_json     = file("${path.module}/mappings/aws-to-gcp.json")
  ensure_cloud2code_script     = file("${path.module}/scripts/ensure_cloud2code.sh")
  # Keep in lockstep with scripts/stage-runner.sh SCRIPT_PACK_VERSION and a
  # published pack-* GitHub release. 20260911.28 was bumped without a release.
  script_pack_version = "20260930.05"
  script_pack_git_ref = "main"
  # Baked into the runner image under /opt, not under HOME. The ACA Azure Files
  # share mounts over /home/runner, so a pack under HOME depends on the
  # entrypoint copying it into the share on every revision. That copy failed
  # silently in session 8ea42edd: /opt held 20260911.4 while preflight looked
  # under HOME and reported the pack missing. /opt cannot be masked.
  script_pack_preload_dir = "/opt/aws-migrator/script-pack/${local.script_pack_version}"

  # Nile-Factory runner image (GHCR). Bakes script pack + opa/tofu/cloud2code; pin pack-* tag to script_pack_version.
  nile_factory_runner_image_repository = "ghcr.io/walmart-stackgen/nile-factory-runner"
  nile_factory_runner_image_tag        = "pack-${local.script_pack_version}"
  nile_factory_runner_image            = "${local.nile_factory_runner_image_repository}:${local.nile_factory_runner_image_tag}"
  nile_factory_runner_allowed_clis     = ""
  script_pack_allocate_sha256          = sha256(local.allocate_manifest_script)
  script_pack_decomposer_sha256        = sha256(local.tfstate_monolith_decomposer)
  script_pack_runner_sha256            = sha256(file("${path.module}/scripts/stage-runner.sh"))
  script_pack_catalog_py_sha256        = sha256(local.azure_mapping_catalog_script)
  script_pack_catalog_json_sha256      = sha256(local.azure_mapping_catalog_json)
  script_pack_gcp_catalog_py_sha256    = sha256(local.gcp_mapping_catalog_script)
  script_pack_gcp_catalog_json_sha256  = sha256(local.gcp_mapping_catalog_json)

  # Exclude efficiency/mini models from the agent so create_agent sub-agents do not route to gpt-*-mini / flash for paste-heavy work.
  filtered_non_trivial_model_names = [
    for name in compact(var.model_names) : name if !can(regex("(?i)(mini|flash|nano|haiku|efficiency)", name))
  ]
  non_trivial_model_names = length(compact(var.non_trivial_model_names)) > 0 ? compact(var.non_trivial_model_names) : (
    length(local.filtered_non_trivial_model_names) > 0 ? local.filtered_non_trivial_model_names : compact(var.model_names)
  )

  ingest_bootstrap_script = trimspace(local.ingest_execute_series_body)
  ingest_bootstrap_sha256 = sha256(local.ingest_bootstrap_script)
  # Single execute_command copied from spawn context. It invokes the raw
  # preloaded bootstrap; no script-pack bytes are transported through runner env.
  # Prefixed with fetch at definition site below (after runner_script_pack_fetch_bootstrap).
  ingest_bootstrap_execute_command_core = "WORKFLOW_RUN_ID='{{workflow_run_id}}' DBSPLIT_EMBEDDED=1 bash ${local.script_pack_preload_dir}/ingest-bootstrap.sh"

  subagent_budget_defaults = {
    script_runner_max_llm_calls                = 40
    script_runner_max_tool_iterations          = 48
    script_runner_timeout_seconds              = 3600
    registry_codegen_max_llm_calls             = 60
    registry_codegen_max_tool_iterations       = 48
    registry_codegen_timeout_seconds           = 900
    hcl_hydrate_batch_max_llm_calls            = 60
    hcl_hydrate_batch_max_tool_iterations      = 48
    hcl_hydrate_batch_timeout_seconds          = 600
    plan_convergence_batch_max_llm_calls       = 60
    plan_convergence_batch_max_tool_iterations = 48
    plan_convergence_batch_timeout_seconds     = 900
  }
  subagent_budgets = {
    for key, default in local.subagent_budget_defaults :
    key => coalesce(try(var.subagent_budgets[key], null), default)
  }

  dbsplit_script_pack_preload_helpers = templatefile(
    "${path.module}/templates/dbsplit-script-pack-env.sh.tftpl",
    {
      script_pack_version                 = local.script_pack_version
      script_pack_preload_dir             = local.script_pack_preload_dir
      script_pack_tarball_url             = local.script_pack_tarball_url
      script_pack_release_repo            = trimspace(var.script_pack_release_repo)
      script_pack_allocate_sha256         = local.script_pack_allocate_sha256
      script_pack_decomposer_sha256       = local.script_pack_decomposer_sha256
      script_pack_runner_sha256           = local.script_pack_runner_sha256
      script_pack_catalog_py_sha256       = local.script_pack_catalog_py_sha256
      script_pack_catalog_json_sha256     = local.script_pack_catalog_json_sha256
      script_pack_gcp_catalog_py_sha256   = local.script_pack_gcp_catalog_py_sha256
      script_pack_gcp_catalog_json_sha256 = local.script_pack_gcp_catalog_json_sha256
    },
  )

  template_vars = {
    module_prefix                       = local.module_prefix
    suffix                              = local.suffix
    shell_tool_prefix                   = local.shell_tool_prefix
    remote_runner_name                  = local.resolved_remote_runner_name
    github_tool_prefix                  = local.resolved_github_integration_name
    aws_tool_prefix                     = local.resolved_aws_integration_name
    max_iterations                      = var.max_convergence_iterations
    remote_runner_block                 = local.remote_runner_block
    stage_runner_script                 = local.stage_runner_script
    allocate_manifest_script            = local.allocate_manifest_script
    tfstate_monolith_decomposer_script  = local.tfstate_monolith_decomposer
    script_pack_version                 = local.script_pack_version
    script_pack_preload_dir             = local.script_pack_preload_dir
    script_pack_git_ref                 = local.script_pack_git_ref
    script_pack_allocate_sha256         = local.script_pack_allocate_sha256
    script_pack_decomposer_sha256       = local.script_pack_decomposer_sha256
    script_pack_runner_sha256           = local.script_pack_runner_sha256
    script_pack_catalog_py_sha256       = local.script_pack_catalog_py_sha256
    script_pack_catalog_json_sha256     = local.script_pack_catalog_json_sha256
    script_pack_gcp_catalog_py_sha256   = local.script_pack_gcp_catalog_py_sha256
    script_pack_gcp_catalog_json_sha256 = local.script_pack_gcp_catalog_json_sha256
    runner_work_home                    = local.runner_work_home
    default_grouping_strategy           = var.default_grouping_strategy
    default_max_resources_per_appstack  = var.default_max_resources_per_appstack
    default_iac_repository_url          = trimspace(var.default_iac_repository_url)
    default_branch                      = trimspace(var.default_branch)
    ensure_cloud2code_script            = local.ensure_cloud2code_script
    azure_only_source_branch            = local.azure_only_source_branch
    gcp_only_source_branch              = local.gcp_only_source_branch
    subagent_budgets                    = local.subagent_budgets
    subagent_task_type                  = var.subagent_task_type
    bulk_resources_chunk_size           = 80
    bulk_connections_chunk_size         = 50
    dbsplit_script_pack_preload_helpers = local.dbsplit_script_pack_preload_helpers
    sop_orchestration_name              = local.sop_orchestration_name
    sop_shard_extraction_name           = local.sop_tfstate_splitter_name
    sop_managed_shard_extraction_name   = local.sop_shard_extraction_name
    sop_tfstate_splitter_name           = local.sop_tfstate_splitter_name
    sop_registry_reverse_name           = local.sop_registry_reverse_name
    sop_substate_converge_name          = local.sop_substate_converge_name
    sop_azure_migration_name            = local.sop_azure_migration_name
    sop_governance_conform_name         = local.sop_governance_conform_name
    sop_orphan_bootstrap_name           = local.sop_orphan_bootstrap_name
    destination_iac_wiring_skill_name   = local.destination_iac_wiring_skill_name
    nile_governance_repo_url            = var.nile_governance_repo_url
    nile_governance_ref                 = var.nile_governance_ref
    nile_rules_repo_url                 = var.nile_rules_repo_url
    nile_rules_ref                      = var.nile_rules_ref
    require_azure_live_plan             = local.require_azure_live_plan ? "1" : "0"
    require_gcp_live_plan               = local.require_gcp_live_plan ? "1" : "0"
    dest_harden_parallelism             = "4"
    dest_validate_parallelism           = "4"
    runner_git_env_prefix               = local.runner_git_env_prefix
    runner_pack_entry_invoke            = local.runner_pack_entry_invoke
    evidence_primary_name               = local.evidence_primary_name
    # Acquisition hygiene: exclude workforce/human IAM + never-map noise, but KEEP
    # application IAM (roles, customer policies, inline role policies, attachments,
    # instance profiles) so custom permission surfaces convert to destination IAM.
    # Walle Deny blocks human IAM APIs only — ListRoles/GetPolicy remain allowed.
    # Only types cloud2code get-supported-resources -c aws accepts on --exclude.
    # Folded S3/KMS attribute types are not supported filters in cloud2code 0.5.x.
    default_cloud2code_exclude = join(",", [
      "aws_athena_workgroup",
      "aws_cloudfront_origin_access_identity",
      "aws_db_parameter_group",
      "aws_iam_access_key",
      "aws_iam_account_alias",
      "aws_iam_account_password_policy",
      "aws_iam_group",
      "aws_iam_group_membership",
      "aws_iam_group_policy",
      "aws_iam_group_policy_attachment",
      "aws_iam_openid_connect_provider",
      "aws_iam_saml_provider",
      "aws_iam_server_certificate",
      "aws_iam_user",
      "aws_iam_user_group_membership",
      "aws_iam_user_policy",
      "aws_iam_user_policy_attachment",
      "aws_iam_user_ssh_key",
      "aws_key_pair",
      "aws_route53_resolver_rule_association",
    ])
  }

  template_vars_azure_current_run_source = merge(local.template_vars, {
    azure_only_source_branch = local.azure_current_run_source_branch
  })
  template_vars_gcp_current_run_source = merge(local.template_vars, {
    gcp_only_source_branch = local.azure_current_run_source_branch
  })

  stage_execute_series_paste_max_len = 16384

  # Bootstrap script body is rendered into the raw preloaded host script pack.
  ingest_execute_series_body = templatefile(
    "${path.module}/templates/ingest-execute-series-embedded.sh.tftpl",
    local.template_vars,
  )

  # Final bodies defined after runner_script_pack_fetch_bootstrap (self-heal pack on every stage).
  iac_pr_execute_series_body_core = "WORKFLOW_RUN_ID='{{workflow_run_id}}' IAC_REPOSITORY_URL='${trimspace(var.default_iac_repository_url)}' DEFAULT_BRANCH='${var.default_branch}' DBSPLIT_EMBEDDED=1 bash ${local.script_pack_preload_dir}/iac-pr-bootstrap.sh"

  converge_execute_series_body_core = "WORKFLOW_RUN_ID='{{workflow_run_id}}' DBSPLIT_EMBEDDED=1 bash ${local.script_pack_preload_dir}/converge-bootstrap.sh"

  azure_source_fetch_execute_series_body = templatefile(
    "${path.module}/templates/azure-source-fetch-execute-series-embedded.sh.tftpl",
    local.template_vars,
  )

  azure_current_run_source_fetch_execute_series_body = templatefile(
    "${path.module}/templates/azure-source-fetch-execute-series-embedded.sh.tftpl",
    local.template_vars_azure_current_run_source,
  )

  azure_blueprint_execute_series_body = templatefile(
    "${path.module}/templates/azure-migration-blueprint-execute-series-embedded.sh.tftpl",
    local.template_vars,
  )

  azure_generate_execute_series_body = templatefile(
    "${path.module}/templates/azure-iac-generate-execute-series-embedded.sh.tftpl",
    local.template_vars,
  )

  azure_validate_execute_series_body = templatefile(
    "${path.module}/templates/azure-iac-validate-execute-series-embedded.sh.tftpl",
    local.template_vars,
  )

  azure_harden_execute_series_body = templatefile(
    "${path.module}/templates/azure-iac-harden-execute-series-embedded.sh.tftpl",
    local.template_vars,
  )

  azure_governance_conform_execute_series_body = templatefile(
    "${path.module}/templates/azure-iac-governance-conform-execute-series-embedded.sh.tftpl",
    local.template_vars,
  )

  azure_pr_execute_series_body = templatefile(
    "${path.module}/templates/azure-pr-execute-series-embedded.sh.tftpl",
    local.template_vars,
  )

  gcp_source_fetch_execute_series_body = templatefile(
    "${path.module}/templates/gcp-source-fetch-execute-series-embedded.sh.tftpl",
    local.template_vars,
  )

  gcp_current_run_source_fetch_execute_series_body = templatefile(
    "${path.module}/templates/gcp-source-fetch-execute-series-embedded.sh.tftpl",
    local.template_vars_gcp_current_run_source,
  )

  gcp_blueprint_execute_series_body = templatefile(
    "${path.module}/templates/gcp-migration-blueprint-execute-series-embedded.sh.tftpl",
    local.template_vars,
  )

  gcp_generate_execute_series_body = templatefile(
    "${path.module}/templates/gcp-iac-generate-execute-series-embedded.sh.tftpl",
    local.template_vars,
  )

  gcp_validate_execute_series_body = templatefile(
    "${path.module}/templates/gcp-iac-validate-execute-series-embedded.sh.tftpl",
    local.template_vars,
  )

  gcp_harden_execute_series_body = templatefile(
    "${path.module}/templates/gcp-iac-harden-execute-series-embedded.sh.tftpl",
    local.template_vars,
  )

  gcp_governance_conform_execute_series_body = templatefile(
    "${path.module}/templates/gcp-iac-governance-conform-execute-series-embedded.sh.tftpl",
    local.template_vars,
  )

  gcp_pr_execute_series_body = templatefile(
    "${path.module}/templates/gcp-pr-execute-series-embedded.sh.tftpl",
    local.template_vars,
  )

  # Short pack one-liners (same shape as azure/gcp destination stages). Huge base64
  # pastes truncate under create_agent (session 1d8207c8 quoting EOF) and invented
  # shell hits dash pipefail (sessions 6741e13a / 127f2c35 / af38cc9e).
  # The scan script only ever received workflow_run_id and region, so the
  # optional_inputs cloud2code_include / cloud2code_exclude / cloud2code_tags
  # had no route to the runner and every run scanned the whole region. The env
  # prefix is that route: empty quotes keep the full-region default.
  #
  # SCM github vault sync injects `token` (not GIT_TOKEN). Alias + durable
  # credential helper so IAC_PR and hand-rolled git clone both auth (session 8da4f049).
  # Write under $HOME/.aws-migrator/bin — $HOME/.local/bin is often not writable
  # on the ACA image (session 6dac05f9: Permission denied).
  #
  # Each export is its own statement ending in `;`. A trailing open `export A=1 B=2`
  # glued to later `SOURCE_PR=… bash …/run-destination-stage.sh` makes dash treat
  # the script path as an export name (`bad variable name`, session
  # 55e77bfd / trace 6abefb952b12). Discovery pack-entry invokes already put a
  # `;` after this prefix; destination one-liners append env + bash directly.
  runner_git_env_prefix = "GIT_TOKEN=\"$${GIT_TOKEN:-$${GITHUB_TOKEN:-$${GH_TOKEN:-$${token:-}}}}\"; export GIT_TOKEN; export GH_TOKEN=\"$${GH_TOKEN:-$${GIT_TOKEN}}\"; export GITHUB_TOKEN=\"$${GITHUB_TOKEN:-$${GIT_TOKEN}}\"; export GIT_TERMINAL_PROMPT=0;"
  # Walmart ACA bakes packs into the image and disables vault sync. When /opt lags
  # the module version, fetch the GitHub release tarball before pack scripts run.
  # OpenTofu only escapes $${…} → ${…}; bare $$( stays literal $$( and breaks mktemp.
  # Use unescaped $(mktemp -d) here (not a TF interpolation).
  # Require bootstraps too so a partial extract fails closed (session b506b854).
  runner_script_pack_fetch_bootstrap = "PRELOAD_DIR='${local.script_pack_preload_dir}'; PACK_VER='${local.script_pack_version}'; PACK_REPO='${trimspace(var.script_pack_release_repo)}'; PACK_URL='${local.script_pack_tarball_url}'; if [ ! -f \"$${PRELOAD_DIR}/runner-capability-preflight.sh\" ] || [ ! -f \"$${PRELOAD_DIR}/cloud2code-aws-scan.sh\" ] || [ ! -f \"$${PRELOAD_DIR}/ingest-bootstrap.sh\" ] || [ ! -f \"$${PRELOAD_DIR}/iac-pr-bootstrap.sh\" ] || [ ! -f \"$${PRELOAD_DIR}/converge-bootstrap.sh\" ]; then TOK=\"$${GIT_TOKEN:-$${GITHUB_TOKEN:-$${GH_TOKEN:-$${token:-}}}}\"; export GIT_TOKEN=\"$${TOK}\" GH_TOKEN=\"$${GH_TOKEN:-$${TOK}}\" GITHUB_TOKEN=\"$${GITHUB_TOKEN:-$${TOK}}\"; TMP=$(mktemp -d); if command -v gh >/dev/null 2>&1; then gh release download \"pack-$${PACK_VER}\" -R \"$${PACK_REPO}\" -p \"script-pack-$${PACK_VER}.tar.gz\" -D \"$${TMP}\"; else curl -fsSL -H \"Authorization: Bearer $${TOK}\" -H \"Accept: application/octet-stream\" \"$${PACK_URL}\" -o \"$${TMP}/script-pack-$${PACK_VER}.tar.gz\"; fi; mkdir -p \"$${PRELOAD_DIR}\"; tar -xzf \"$${TMP}/script-pack-$${PACK_VER}.tar.gz\" -C \"$${PRELOAD_DIR}\"; chmod +x \"$${PRELOAD_DIR}\"/*.sh 2>/dev/null || true; rm -rf \"$${TMP}\"; if [ ! -f \"$${PRELOAD_DIR}/runner-capability-preflight.sh\" ] || [ ! -f \"$${PRELOAD_DIR}/cloud2code-aws-scan.sh\" ] || [ ! -f \"$${PRELOAD_DIR}/ingest-bootstrap.sh\" ] || [ ! -f \"$${PRELOAD_DIR}/iac-pr-bootstrap.sh\" ] || [ ! -f \"$${PRELOAD_DIR}/converge-bootstrap.sh\" ]; then echo \"script_pack_error=fetch_incomplete path=$${PRELOAD_DIR} version=$${PACK_VER}\" >&2; ls -la \"$${PRELOAD_DIR}\" >&2 || true; exit 1; fi; echo \"script_pack_fetch=ok path=$${PRELOAD_DIR} version=$${PACK_VER}\"; fi"
  # Short gh|bash entry (session 90082b12 invented script_pack_dir_missing instead of
  # pasting multi-KB inline fetch; session d8faf9c8: browser download URL 404s on
  # private repos — use gh release download / API asset URL instead).
  script_pack_entry_url = "https://github.com/${trimspace(var.script_pack_release_repo)}/releases/download/pack-${local.script_pack_version}/pack-entry.sh"
  # Prefer baked /opt stage scripts when the ACA image already has this pack
  # (embed-script-pack.sh does not copy pack-entry.sh; Walmart disables vault pack
  # sync). After a revision roll GIT_TOKEN/`token` may be absent and
  # `gh release download` fails before any stage runs (session b55b2b3d / 62970ce6).
  # Fall back to gh pack-entry for greenfield / lagging images.
  # Prefix already ends with `;` — do not add another or dash sees `;;` (session c6cb3339).
  # Use "$@"/$(mktemp) unescaped — $${@} corrupts under TF interpolation.
  # Drop stale Azure Files ~/.aws cache so SDK does not chase expired IMDS/SSO
  # before typed-secret env keys (session 3f867683 / ced6484d).
  runner_aws_cred_hygiene = "unset AWS_PROFILE; rm -rf \"$${HOME}/.aws/cli/cache\" \"$${HOME}/.aws/sso\" 2>/dev/null || true; echo \"aws_env_keys=$(env | grep '^AWS_' | cut -d= -f1 | tr '\\n' ' ')\"; if [ -f \"$${HOME}/.aws/credentials\" ]; then echo aws_credentials_file=present; else echo aws_credentials_file=absent; fi;"
  # Delegate dispatch to the versioned pack entrypoint instead of pasting a
  # hand-maintained shell case statement into every LLM tool call. pack-entry
  # owns argv→WORKFLOW_RUN_ID mapping and pack self-heal.
  runner_pack_entry_invoke = "${local.runner_git_env_prefix} ${local.runner_aws_cred_hygiene} pack_entry(){ P='${local.script_pack_preload_dir}'; if [ -x \"$${P}/pack-entry.sh\" ]; then exec bash \"$${P}/pack-entry.sh\" \"$@\"; fi; D=$(mktemp -d); gh release download 'pack-${local.script_pack_version}' -R '${trimspace(var.script_pack_release_repo)}' -p pack-entry.sh -D \"$${D}\" && exec bash \"$${D}/pack-entry.sh\" \"$@\"; }; pack_entry"
  # Self-heal pack fetch on every pack-path stage so a faked preflight (session
  # b506b854: printf runner_capability_preflight_ok) cannot leave /opt empty.
  runner_capability_preflight_execute_series_body = "${local.runner_pack_entry_invoke} preflight '{{workflow_run_id}}'"
  ingest_bootstrap_execute_command                = "${local.runner_pack_entry_invoke} ingest '{{workflow_run_id}}'"
  cloud2code_scan_execute_series_body             = "${local.runner_pack_entry_invoke} scan '{{workflow_run_id}}' 'AWS_REGION_PLACEHOLDER' 'CLOUD2CODE_EXCLUDE_PLACEHOLDER'"
  iac_pr_execute_series_body                      = "${local.runner_pack_entry_invoke} iac-pr '{{workflow_run_id}}'"
  converge_execute_series_body                    = "${local.runner_pack_entry_invoke} converge '{{workflow_run_id}}'"

  rendered_persona = trimspace(join("\n\n", compact([
    templatefile("${path.module}/personas/aws-migrator-architect.md.tftpl", local.template_vars),
    trimspace(var.architect_persona_addendum),
  ])))

  rendered_templates = {
    for filename in setunion(
      fileset("${path.module}/templates", "*.md.tftpl"),
      fileset("${path.module}/templates", "*.tmpl.md"),
    ) :
    (endswith(filename, ".tmpl.md") ? replace(filename, ".tmpl.md", ".md") : replace(filename, ".tftpl", "")) => templatefile("${path.module}/templates/${filename}", local.template_vars)
  }

  remote_runner_block = trimspace(<<-RUNNER
    **Primary execution:** all shell, `cloud2code`, `tofu`/`terraform`, `jq`, `git`, and **tfstate generation/download** run on remote runner **`${local.resolved_remote_runner_name}`** via **`${local.shell_tool_prefix}_execute_*`** tools (never Ubuntu CLI). Discovery starts with `runner-capability-preflight` so missing tools fail before scan/ingest. `cloud2code-scan-aws` writes a local tfstate path to `monolith_state_uri`; `stage-runner.sh download-state` then materializes `$WORK_ROOT/state/terraform.tfstate` for decomposition.%{if var.create_remote_runner~}
    Runner registered by Terraform via `sg_remote_runner`; install commands are in module outputs `remote_runner_cli_start_command` / `remote_runner_helm_install_command` — deploy aiden-runner on-prem with **outbound-only** access to mothership before running workflows.%{endif~}
    Per the **Execution Optimization Protocol** (${local.sop_orchestration_name}), multi-step work is batched into one `${local.shell_tool_prefix}_execute_series`; `${local.shell_tool_prefix}_execute_command` is for a single cohesive command; `${local.shell_tool_prefix}_execute_parallel` (or `flow_type:"parallel"` subagent batches) is the only sanctioned fan-out for independent per-group / per-shard work.
    **Runner prerequisites:** deploy **`ghcr.io/walmart-stackgen/nile-factory-runner:pack-${local.script_pack_version}`** (see `remote_runner_image` output) for CLIs + **`opa`** — avoid stock `stackgen-guild-aiden-runner` plus manual `kubectl cp`. The runner image must include **`tofu`/`terraform`**, **`jq`**, **`git`**, **`awscli`**, **`opa`**, `tar`, and either `curl` or `wget`, plus AWS read credentials for the target region. The scan bootstrap downloads pinned Cloud2Code v0.5.6 into `$HOME/.local/bin` when `cloud2code` is absent or outdated; no root access is required. When `runner_git_token` / `runner_aws_*` or `runner_*_env_secret_id` / `remote_runner_typed_secret_refs` are set, Terraform binds **`sg_remote_runner_secrets`** so mothership sync injects git/AWS env on the runner (memory-only) for **`cloud2code import aws`**, **`git clone`**, **`gh pr create`**, and plan hydration. GitHub SCM vault secrets often expose **`token`** (not `GIT_TOKEN`); preflight and IAC_PR alias `token` → `GIT_TOKEN`/`GH_TOKEN`, atomically install the durable helper script, and pass Git helper/user settings through process-scoped `GIT_CONFIG_*` environment variables. They never rewrite the shared runner `~/.gitconfig`, avoiding concurrent workflow lock races.%{if var.remote_runner_script_pack_sync_enabled~} Terraform also binds a script-pack vault secret (`SCRIPT_PACK_*` metadata). aiden-runner secret sync refreshes those keys; `runner-capability-preflight` runs `sync-script-pack-from-env.sh` to download the tarball into **`${local.script_pack_preload_dir}`** when the pack version or sha gates change — **no runner redeploy** on script bumps (bump `script_pack_version`, publish the release tarball, `tofu apply`).%{else~} The large tfstate decomposition script pack must be preloaded on the runner at **`${local.script_pack_preload_dir}`**.%{endif~} Each workflow copies the pack into `$WORK_ROOT/scripts`; do not pass it through runner environment variables.
    Persist artifact paths (plan JSON, state snapshots) via `note` keys `remote_runner_artifacts`. If `${local.shell_tool_prefix}_execute_*` is unavailable (runner offline), emit **`blocked:remote_runner_shell_unavailable: "true"`** and stop — do not fall back to inline shell on the architect.
    RUNNER
  )
}

# =============================================================================
# Owned integrations — GitHub (gh api) and AWS (aws_cli_* MCP). Shell / tofu /
# state download run on the attached remote runner, not Ubuntu CLI.
# =============================================================================

resource "terraform_data" "github_integration_required" {
  lifecycle {
    precondition {
      condition     = trimspace(local.resolved_github_integration_name) != ""
      error_message = "aios-agent-aws-migrator needs a GitHub Guild integration: provide `github_secret_id` (module provisions one) or `existing_github_integration_name`."
    }
  }
}

resource "terraform_data" "aws_integration_required" {
  lifecycle {
    precondition {
      condition     = trimspace(local.resolved_aws_integration_name) != ""
      error_message = "aios-agent-aws-migrator needs an AWS Guild integration: provide `aws_secret_id` (module provisions one) or `existing_aws_integration_name`."
    }
  }
}

resource "terraform_data" "runner_git_secret_input" {
  lifecycle {
    precondition {
      condition     = !(local.create_runner_git_env_secret && trimspace(var.runner_git_env_secret_id) != "")
      error_message = "Set either runner_git_token (module creates vault secret) or runner_git_env_secret_id, not both."
    }
    precondition {
      condition     = !(local.create_runner_aws_env_secret && trimspace(var.runner_aws_env_secret_id) != "")
      error_message = "Set either runner_aws_access_key_id + runner_aws_secret_access_key or runner_aws_env_secret_id, not both."
    }
  }
}

module "github_integration" {
  count  = local.provision_github ? 1 : 0
  source = "../aios-integration-github"

  integration_name   = local.github_integration_name
  existing_secret_id = var.github_secret_id
  description        = "Shared GitHub cloud integration (issue/PR triage, gh api). Not tied to a single agent."
}

module "aws_integration" {
  count  = local.provision_aws ? 1 : 0
  source = "../aios-integration-aws"

  integration_name   = local.aws_integration_name
  existing_secret_id = var.aws_secret_id
  description        = "Shared AWS cloud integration (read-only discovery via aws_cli_* tools). Not tied to a single agent."
}

# =============================================================================
# Remote runner env secrets (flat metadata for mothership sync → aiden-runner)
# =============================================================================

resource "sg_secret" "runner_git_env" {
  count = local.create_runner_git_env_secret ? 1 : 0

  name        = "${local.module_prefix}-runner-git-env${local.suffix}"
  description = "Git HTTPS credentials for ${local.resolved_remote_runner_name} (GIT_TOKEN/GIT_HOST for clone + gh pr)."
  category    = "Provider"
  subcategory = "github"
  metadata = {
    token        = var.runner_git_token
    GIT_TOKEN    = var.runner_git_token
    GIT_HOST     = trimspace(var.runner_git_host) != "" ? trimspace(var.runner_git_host) : "github.com"
    GIT_USERNAME = trimspace(var.runner_git_username) != "" ? trimspace(var.runner_git_username) : "x-access-token"
    GH_TOKEN     = var.runner_git_token
    GITHUB_TOKEN = var.runner_git_token
  }
}

resource "sg_secret" "runner_aws_env" {
  count = local.create_runner_aws_env_secret ? 1 : 0

  name        = "${local.module_prefix}-runner-aws-env${local.suffix}"
  description = "AWS credentials for ${local.resolved_remote_runner_name} (S3 state download + tofu AWS provider)."
  category    = "CloudProvider"
  subcategory = "aws"
  metadata = {
    AWS_ACCESS_KEY_ID     = var.runner_aws_access_key_id
    AWS_SECRET_ACCESS_KEY = var.runner_aws_secret_access_key
    AWS_REGION            = trimspace(var.runner_aws_region)
    AWS_DEFAULT_REGION    = trimspace(var.runner_aws_region)
  }
}

resource "sg_secret" "runner_script_pack" {
  count = local.create_runner_script_pack_env_secret ? 1 : 0

  name        = "${local.module_prefix}-runner-script-pack${local.suffix}"
  description = "Script pack sync metadata for ${local.resolved_remote_runner_name} (SCRIPT_PACK_* env keys → aiden-runner secret sync)."
  # Vault does not support the historical `env` subcategory. Use the generic
  # provider secret shape accepted by Vault; runner sync consumes the flat
  # SCRIPT_PACK_* metadata keys below.
  category    = "Provider"
  subcategory = "generic"
  metadata = {
    value                               = local.script_pack_version
    SCRIPT_PACK_VERSION                 = local.script_pack_version
    SCRIPT_PACK_PRELOAD_DIR             = local.script_pack_preload_dir
    SCRIPT_PACK_TARBALL_URL             = local.script_pack_tarball_url
    SCRIPT_PACK_GIT_REF                 = local.script_pack_git_ref
    SCRIPT_PACK_ALLOCATE_SHA256         = local.script_pack_allocate_sha256
    SCRIPT_PACK_DECOMPOSER_SHA256       = local.script_pack_decomposer_sha256
    SCRIPT_PACK_RUNNER_SHA256           = local.script_pack_runner_sha256
    SCRIPT_PACK_CATALOG_PY_SHA256       = local.script_pack_catalog_py_sha256
    SCRIPT_PACK_CATALOG_JSON_SHA256     = local.script_pack_catalog_json_sha256
    SCRIPT_PACK_GCP_CATALOG_PY_SHA256   = local.script_pack_gcp_catalog_py_sha256
    SCRIPT_PACK_GCP_CATALOG_JSON_SHA256 = local.script_pack_gcp_catalog_json_sha256
  }
}

# Stages assert the handoff carries local.script_pack_version, but the value the
# runner reports comes from a constant inside stage-runner.sh. Catch drift at
# plan time; otherwise the reported version silently describes a different pack
# than the one the preload directory and sha gates refer to.
check "script_pack_version_matches_stage_runner" {
  assert {
    condition     = can(regex("SCRIPT_PACK_VERSION=\"${local.script_pack_version}\"", local.stage_runner_script))
    error_message = "scripts/stage-runner.sh SCRIPT_PACK_VERSION does not match local.script_pack_version ${local.script_pack_version}; bump both together and re-preload the runner"
  }
}

check "ingest_bootstrap_execute_command_budget" {
  assert {
    condition     = length(local.ingest_bootstrap_execute_command) <= local.stage_execute_series_paste_max_len
    error_message = "ingest bootstrap command length ${length(local.ingest_bootstrap_execute_command)} exceeds ${local.stage_execute_series_paste_max_len}; keep only the small bootstrap inline and preload large scripts on the runner"
  }
}

check "iac_pr_execute_series_paste_budget" {
  assert {
    condition     = length(local.iac_pr_execute_series_body) <= local.stage_execute_series_paste_max_len
    error_message = "iac-pr execute series body length ${length(local.iac_pr_execute_series_body)} exceeds ${local.stage_execute_series_paste_max_len} — do not inline script-pack payloads in spawn paste"
  }
}

check "converge_execute_series_paste_budget" {
  assert {
    condition     = length(local.converge_execute_series_body) <= local.stage_execute_series_paste_max_len
    error_message = "converge execute series body length ${length(local.converge_execute_series_body)} exceeds ${local.stage_execute_series_paste_max_len} — do not inline script-pack payloads in spawn paste"
  }
}

check "cloud2code_scan_execute_series_paste_budget" {
  assert {
    condition     = length(local.cloud2code_scan_execute_series_body) <= local.stage_execute_series_paste_max_len
    error_message = "cloud2code scan execute series body length ${length(local.cloud2code_scan_execute_series_body)} exceeds ${local.stage_execute_series_paste_max_len} — keep the runner scan compact"
  }
}

check "runner_capability_preflight_execute_series_paste_budget" {
  assert {
    condition     = length(local.runner_capability_preflight_execute_series_body) <= local.stage_execute_series_paste_max_len
    error_message = "runner capability preflight execute series body length ${length(local.runner_capability_preflight_execute_series_body)} exceeds ${local.stage_execute_series_paste_max_len} — keep the preflight compact"
  }
}

check "azure_source_fetch_execute_series_paste_budget" {
  assert {
    condition     = length(local.azure_source_fetch_execute_series_body) <= local.stage_execute_series_paste_max_len
    error_message = "azure source fetch execute series body length ${length(local.azure_source_fetch_execute_series_body)} exceeds ${local.stage_execute_series_paste_max_len} — keep Azure runner calls compact"
  }
}

check "azure_blueprint_execute_series_paste_budget" {
  assert {
    condition     = length(local.azure_blueprint_execute_series_body) <= local.stage_execute_series_paste_max_len
    error_message = "azure blueprint execute series body length ${length(local.azure_blueprint_execute_series_body)} exceeds ${local.stage_execute_series_paste_max_len} — keep Azure runner calls compact"
  }
}

check "azure_generate_execute_series_paste_budget" {
  assert {
    condition     = length(local.azure_generate_execute_series_body) <= local.stage_execute_series_paste_max_len
    error_message = "azure generate execute series body length ${length(local.azure_generate_execute_series_body)} exceeds ${local.stage_execute_series_paste_max_len} — keep Azure runner calls compact"
  }
}

check "azure_validate_execute_series_paste_budget" {
  assert {
    condition     = length(local.azure_validate_execute_series_body) <= local.stage_execute_series_paste_max_len
    error_message = "azure validate execute series body length ${length(local.azure_validate_execute_series_body)} exceeds ${local.stage_execute_series_paste_max_len} — keep Azure runner calls compact"
  }
}

check "azure_pr_execute_series_paste_budget" {
  assert {
    condition     = length(local.azure_pr_execute_series_body) <= local.stage_execute_series_paste_max_len
    error_message = "azure PR execute series body length ${length(local.azure_pr_execute_series_body)} exceeds ${local.stage_execute_series_paste_max_len} — keep Azure runner calls compact"
  }
}

# =============================================================================
# Remote runner (required — primary shell / tofu / state-download execution)
# =============================================================================

module "remote_runner" {
  source = "../aios-remote-runner"

  create_runner = var.create_remote_runner
  name          = local.resolved_remote_runner_name
  description   = trimspace(var.remote_runner_description) != "" ? trimspace(var.remote_runner_description) : "Remote runner for ${local.agent_name} (tofu plan, state download, git clone behind the customer firewall)."
  labels        = var.remote_runner_labels

  bind_runner_secrets           = local.runner_secrets_sync_configured
  typed_secret_refs             = local.runner_typed_secret_refs
  generic_secret_ref_ids        = local.runner_generic_secret_ref_ids
  secrets_sync_interval_seconds = var.remote_runner_secrets_sync_interval_seconds
}

# =============================================================================
# Agent — AWS migrator architect (destination from workflow intent)
# =============================================================================

resource "sg_agent" "aws_migrator_architect" {
  name        = local.agent_name
  persona     = local.rendered_persona
  model_names = local.non_trivial_model_names

  hitl = {
    always_allowed = local.auto_approve_all_available_tools
  }

  # Match the Demo Workspace operator setting: every currently exposed tool call is auto-approved.
  auto_approve_tools = [
    for tool_name in local.auto_approve_all_available_tools : {
      tool = tool_name
    }
  ]

  remote_runners = var.remote_runner_attach_to_agent ? toset([module.remote_runner.runner_name]) : null

  integrations = distinct(concat(
    compact([
      local.resolved_github_integration_name,
      local.resolved_aws_integration_name,
      local.resolved_azure_integration_name,
      local.resolved_gcp_integration_name,
    ]),
    compact(var.extra_agent_integration_names),
  ))

  # Provider 0.1.37 PUTs auto_approve_tools with auto_extract; Guild API rejects
  # unknown field auto_extract (PARSING_ERROR). Ignore until provider/API align,
  # otherwise in-place agent updates block dependent workflow applies.
  lifecycle {
    ignore_changes = [
      auto_approve_tools,
    ]
  }
}

resource "sg_agent_budget" "aws_migrator_architect" {
  agent_name  = sg_agent.aws_migrator_architect.name
  limit_usd   = 25
  period_type = "daily"
}

resource "sg_agent_policy_attachment" "aws_migrator_architect_dangerous_ops" {
  agent_name = sg_agent.aws_migrator_architect.name
  policy_id  = var.policy_ids.dangerous_ops
  enabled    = true
}

# =============================================================================
# Runbooks (Guild skills)
# =============================================================================

resource "sg_runbook_sop" "cloud2code_aws_region_scan" {
  name        = local.sop_cloud2code_scan_name
  approve     = true
  description = trimspace(local.rendered_templates["cloud2code-aws-region-scan.md"])
}

# Generic (no numbered Procedure). Bound explicitly on aws-cloud-discovery so
# Guild smart-runbook discovery cannot auto-pick cloud2code/orchestration SOPs
# and DecomposeExecute them inside preflight (session 577ff7ec).
resource "sg_runbook_sop" "discovery_stage_contract" {
  name        = local.sop_discovery_stage_contract_name
  approve     = true
  description = trimspace(local.rendered_templates["discovery-stage-contract.md"])
}

resource "sg_runbook_sop" "aws_discovery_pr_review" {
  name        = local.aws_discovery_pr_review_skill_name
  approve     = true
  description = trimspace(local.rendered_templates["aws-discovery-pr-review.md"])
}

resource "sg_runbook_sop" "terraform_diagnose_edit_verify" {
  name        = local.terraform_diagnose_skill_name
  approve     = true
  description = trimspace(local.rendered_templates["terraform-diagnose-edit-verify.md"])
}

resource "sg_runbook_sop" "rego_plan_reasoning" {
  name        = local.rego_plan_reasoning_skill_name
  approve     = true
  description = trimspace(local.rendered_templates["rego-plan-reasoning.md"])
}

resource "sg_runbook_sop" "mapping_provider_schema_reasoning" {
  name        = local.mapping_provider_schema_skill_name
  approve     = true
  description = trimspace(local.rendered_templates["mapping-catalog-provider-schema.md"])
}

resource "sg_runbook_sop" "mapping_catalog_knowledge" {
  name        = local.mapping_catalog_knowledge_name
  approve     = true
  description = trimspace(local.rendered_templates["discovery-mapping-review-reference.md"])
}

resource "sg_runbook_sop" "destination_iac_wiring_readiness" {
  name        = local.destination_iac_wiring_skill_name
  approve     = true
  description = trimspace(local.rendered_templates["destination-iac-wiring-readiness.md"])
}

resource "sg_runbook_sop" "aws_migrator_orchestration" {
  name        = local.sop_orchestration_name
  approve     = true
  description = trimspace(local.rendered_templates["db-state-split-orchestration.md"])
}

resource "sg_runbook_sop" "terraform_state_shard_extraction" {
  name        = local.sop_shard_extraction_name
  approve     = true
  description = trimspace(local.rendered_templates["terraform-state-shard-extraction.md"])
}

resource "sg_runbook_sop" "tfstate_splitter" {
  name        = local.sop_tfstate_splitter_name
  approve     = true
  description = trimspace(local.rendered_templates["terraform-state-shard-extraction.md"])
}

resource "sg_runbook_sop" "terraform_registry_reverse_iac" {
  name        = local.sop_registry_reverse_name
  approve     = true
  description = trimspace(local.rendered_templates["terraform-registry-reverse-iac.md"])
}

resource "sg_runbook_sop" "terraform_substate_convergence" {
  name        = local.sop_substate_converge_name
  approve     = true
  description = trimspace(local.rendered_templates["terraform-substate-convergence.md"])
}

resource "sg_runbook_sop" "azure_demo_migration_profile" {
  name        = local.sop_azure_migration_name
  approve     = true
  description = trimspace(local.rendered_templates["azure-demo-migration-profile.md"])
}

resource "sg_runbook_sop" "nile_governance_learn_and_conform" {
  name        = local.sop_governance_conform_name
  approve     = true
  description = trimspace(local.rendered_templates["nile-governance-learn-and-conform.md"])
}

resource "sg_runbook_sop" "orphan_iac_module_bootstrap" {
  name        = local.sop_orphan_bootstrap_name
  approve     = true
  description = trimspace(local.rendered_templates["orphan-iac-module-bootstrap.md"])
}

resource "sg_runbook_sop" "cce_iac_alignment" {
  count       = var.enable_cce ? 1 : 0
  name        = local.sop_cce_iac_alignment
  approve     = true
  description = trimspace(templatefile("${path.module}/templates/cce-iac-alignment.md.tftpl", {}))
}

# =============================================================================
# Evidence checklists — proof-of-work for primary vs orphan workflows
# =============================================================================

resource "sg_evidence_checklist" "aws_migrator_discovery_evidence" {
  name        = local.evidence_primary_name
  description = "Required proof for AWS discovery: scan completed, all resources accounted for, readable Terraform generated, format and validation passed, and pull request opened."
  approve     = true
  required_items = [
    "cloud2code_region_scan_completed",
    "cloud2code_tfstate_recorded",
    "monolith_resource_count_recorded",
    "aggregate_shard_count_matches_monolith",
    "terraform_files_generated",
    "terraform_format_passed",
    "terraform_validation_passed",
    "iac_pr_url_recorded",
  ]
  optional_items = [
    "terraform_zero_change_plan",
    "grouping_readiness_analysis",
    "orphan_secondary_handoff_link",
    "cloud2code_log_path",
    "source_iac_branch_recorded",
  ]
  scoring = {
    min_required         = 8
    confidence_threshold = 0.8
  }
  metadata = {
    playbook                  = "aws-cloud-discovery"
    cloud2code_note_key       = "cloud2code_tfstate_path"
    hcl_hydration_note_prefix = "hcl_hydration_status:"
    hcl_hydration_runbook     = local.sop_registry_reverse_name
    hcl_hydration_section     = "HCL hydration (mandatory — no human \"HCL author\" handoff)"
  }
}

resource "sg_evidence_checklist" "aws_migrator_azure_only_evidence" {
  name        = local.evidence_azure_only_name
  description = "Proof-of-work for azure-migration-pr: source AWS IaC from discovery PR/branch, Azure blueprint and IaC, validation, and sibling Azure PR."
  approve     = true
  required_items = [
    "azure_source_iac_fetched",
    "azure_migration_blueprint_recorded",
    "azure_iac_generated",
    "azure_iac_validation_evidence",
    "azure_iac_harden_evidence",
    "azure_iac_governance_evidence",
    "azure_pr_url_recorded",
  ]
  optional_items = [
    "azure_plan_json",
    "azure_review_needed_summary",
    "azure_harden_findings_summary",
    "azure_governance_sha_recorded",
    "source_iac_branch_recorded",
    "source_pr_recorded",
  ]
  scoring = {
    min_required         = 7
    confidence_threshold = 0.8
  }
  metadata = {
    playbook              = "azure-migration-pr"
    source_repository_url = trimspace(var.default_iac_repository_url)
    source_branch         = local.azure_only_source_branch
  }
}

resource "sg_evidence_checklist" "aws_migrator_gcp_only_evidence" {
  name        = local.evidence_gcp_only_name
  description = "Proof-of-work for gcp-migration-pr: source AWS IaC from discovery PR/branch, GCP blueprint and IaC, validation, and sibling GCP PR."
  approve     = true
  required_items = [
    "gcp_source_iac_fetched",
    "gcp_migration_blueprint_recorded",
    "gcp_iac_generated",
    "gcp_iac_validation_evidence",
    "gcp_iac_harden_evidence",
    "gcp_iac_governance_evidence",
    "gcp_pr_url_recorded",
  ]
  optional_items = [
    "gcp_plan_json",
    "gcp_review_needed_summary",
    "gcp_harden_findings_summary",
    "gcp_governance_sha_recorded",
    "source_iac_branch_recorded",
    "source_pr_recorded",
  ]
  scoring = {
    min_required         = 7
    confidence_threshold = 0.8
  }
  metadata = {
    playbook              = "gcp-migration-pr"
    source_repository_url = trimspace(var.default_iac_repository_url)
    source_branch         = local.gcp_only_source_branch
  }
}

resource "sg_evidence_checklist" "orphan_iac_module_authoring_evidence" {
  name        = local.evidence_orphan_name
  description = "Proof-of-work for orphan module pipeline: bundle classified, module scaffold validated, memory and PR handoff."
  approve     = true
  required_items = [
    "orphans_bundle_classification_summary",
    "module_fmt_validate_plan_evidence",
    "modularization_memory_or_pr_link",
  ]
  optional_items = ["test_results_or_ci_link"]
  scoring = {
    min_required         = 2
    confidence_threshold = 0.7
  }
  metadata = { playbook = "orphan-iac-module-authoring" }
}

# =============================================================================
# Optional GitHub webhook → primary workflow
# =============================================================================

resource "sg_webhook" "github_aws_migrator" {
  count = var.enable_github_webhook ? 1 : 0

  name        = local.webhook_name
  target_type = "workflow"
  target_name = sg_workflow.aws_migrator_discovery.name
  action      = "GitHub issue or PR about scanning an AWS account/region with cloud2code, decomposing the synthesized Terraform state into logical project groups, reverse-engineering HCL, proving Terraform plans, generating best-effort Azure IaC, validating it, and opening an Azure PR."
  enabled     = true
}
