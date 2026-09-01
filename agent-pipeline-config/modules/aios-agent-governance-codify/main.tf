locals {
  module_prefix = "governance-codify"

  suffix = trimspace(var.name_suffix) == "" ? "" : "-${trimspace(var.name_suffix)}"

  agent_name              = "governance-codify-architect${local.suffix}"
  workflow_name           = "governance-rules-codify${local.suffix}"
  sop_governance_codify_name   = "governance-rules-codify-sop${local.suffix}"
  opa_codify_method_name       = "governance-opa-codify-method${local.suffix}"
  evidence_name                = "governance-rules-codify-evidence${local.suffix}"

  resolved_github_integration_name = trimspace(var.existing_github_integration_name)

  github_tool_prefix = local.resolved_github_integration_name

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
      "${local.github_tool_prefix}_${tool_name}"
    ],
    [
      "note",
      "read_notes",
      "web_search",
      "create_agent",
    ],
  ))

  codify_manifest_schema   = trimspace(file("${path.module}/schemas/nile-codify-manifest.v1.json"))
  codify_inventory_schema  = trimspace(file("${path.module}/schemas/nile-codify-inventory.v1.json"))
  github_rules_validate_yml = trimspace(templatefile("${path.module}/templates/github-rules-validate.yml.tftpl", {
    github_check_name = var.github_check_name
  }))
  # Terraform templatefile treats ${...} as interpolation; shell vars in the script use $${...}.
  rules_run_tests_sh = trimspace(templatefile("${path.module}/templates/run-tests.sh.tftpl", {}))

  template_vars = {
    github_tool_prefix                    = local.github_tool_prefix
    sop_governance_codify_name            = local.sop_governance_codify_name
    opa_codify_method_name                = local.opa_codify_method_name
    default_source_repository_url         = trimspace(var.default_source_repository_url)
    default_source_ref                    = trimspace(var.default_source_ref)
    default_target_repository_url         = trimspace(var.default_target_repository_url)
    default_target_ref                    = trimspace(var.default_target_ref)
    default_source_repo_full              = local.default_source_repo_full
    default_target_repo_full              = local.default_target_repo_full
    source_clone_dir                      = local.source_clone_dir
    target_clone_dir                      = local.target_clone_dir
    default_rules_output_dir              = trimspace(var.default_rules_output_dir)
    default_base_branch                   = trimspace(var.default_base_branch)
    github_check_name                     = trimspace(var.github_check_name)
    codify_manifest_schema                = local.codify_manifest_schema
    codify_inventory_schema               = local.codify_inventory_schema
    github_rules_validate_yml             = local.github_rules_validate_yml
    rules_run_tests_sh                    = local.rules_run_tests_sh
    codify_pr_execute_series_template     = local.codify_pr_execute_series_template
    codify_branch_execute_series_template = local.codify_branch_execute_series_template
    codify_intake_execute_series_template = local.codify_intake_execute_series_template
  }

  rendered_persona = templatefile("${path.module}/personas/governance-codify-architect.md.tftpl", local.template_vars)

  rendered_templates = {
    for filename in fileset("${path.module}/templates", "*.md.tftpl") :
    replace(filename, ".md.tftpl", ".md") => trimspace(templatefile("${path.module}/templates/${filename}", local.template_vars))
  }
}

resource "sg_agent" "governance_codify_architect" {
  name        = local.agent_name
  persona     = local.rendered_persona
  model_names = compact(var.model_names)

  hitl = {
    always_allowed = local.auto_approve_all_available_tools
  }

  auto_approve_tools = [
    for tool_name in local.auto_approve_all_available_tools : {
      tool = tool_name
    }
  ]

  integrations = [local.resolved_github_integration_name]

  lifecycle {
    ignore_changes = [
      auto_approve_tools,
    ]
  }
}

resource "sg_agent_budget" "governance_codify_architect" {
  agent_name  = sg_agent.governance_codify_architect.name
  limit_usd   = 25
  period_type = "daily"
}

resource "sg_runbook_sop" "governance_rules_codify" {
  name        = local.sop_governance_codify_name
  approve     = true
  description = local.rendered_templates["governance-rules-codify.md"]
}

resource "sg_runbook_sop" "governance_opa_codify_method" {
  name        = local.opa_codify_method_name
  approve     = true
  description = local.rendered_templates["governance-opa-codify-method.md"]
}

resource "sg_evidence_checklist" "governance_rules_codify_evidence" {
  name        = local.evidence_name
  description = "Proof-of-work for governance-rules-codify: inventory, codified rules, PR opened, CI green."
  approve     = true
  required_items = [
    "codify_inventory_recorded",
    "codify_rules_written",
    "codify_pr_opened",
    "codify_ci_green",
    "rules_codify_ok",
    "rules_pr_url",
  ]
  optional_items = [
    "codify_skipped_unchanged",
  ]
  scoring = {
    min_required         = 4
    confidence_threshold = 0.8
  }
  metadata = {
    playbook            = "governance-rules-codify"
    inventory_note_key  = "codify_inventory_json"
    success_note_key    = "rules_codify_ok"
    pr_url_note_key     = "rules_pr_url"
    github_check_name   = var.github_check_name
  }
}
