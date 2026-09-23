# =============================================================================
# Deployment: walmart (Nile-Staging / customer-managed integrations)
# =============================================================================
# Phase 1 (enable_agent_stack = false): StackGen-only bootstrap — dangerous-ops
# policy and optional Azure OpenAI models. No AWS/Azure CLI creds required.
#
# Phase 1b (enable_governance_codify = true): GitHub integration (optional
# provision_github_integration) + governance-rules-codify workflow only.
#
# Phase 2 (enable_agent_stack = true): attach agent + workflows to integrations
# and a remote runner the customer creates in the StackGen UI. TF never creates
# cloud integrations or registers a runner (except optional GitHub provision).

locals {
  provision_github = var.provision_github_integration && trimspace(var.github_token) != ""
  use_existing_github = !local.provision_github && (
    var.enable_agent_stack || var.enable_governance_codify
  )
  resolved_github_integration_name = local.provision_github ? module.github_integration[0].integration_name : (
    local.use_existing_github ? data.sg_guild_integration.github[0].name : ""
  )
  # Prefer explicit customer model names so apply does not wipe UI selections with [].
  resolved_model_names = length(compact(var.model_names)) > 0 ? compact(var.model_names) : (
    local.enable_azure_openai ? [for m in var.azure_openai_models : m.name] : []
  )
}

resource "sg_policy" "dangerous_ops" {
  name        = "dangerous-ops"
  description = "Gate destructive or off-hours high-risk shell commands with HITL approval."
  type        = "logic"
  rego_source = file("${path.module}/policies/dangerous-ops.rego")
}

resource "terraform_data" "agent_stack_prerequisites" {
  count = var.enable_agent_stack ? 1 : 0

  lifecycle {
    precondition {
      condition     = local.provision_github || trimspace(var.github_integration_name) != ""
      error_message = "enable_agent_stack requires github_integration_name (existing UI integration) or provision_github_integration with github_token."
    }
    precondition {
      condition     = trimspace(var.aws_integration_name) != ""
      error_message = "enable_agent_stack requires aws_integration_name — customer must create the AWS integration in StackGen UI first."
    }
    precondition {
      condition     = trimspace(var.remote_runner_name) != ""
      error_message = "enable_agent_stack requires remote_runner_name — customer must register and start the remote runner first."
    }
  }
}

resource "terraform_data" "governance_codify_prerequisites" {
  count = var.enable_governance_codify ? 1 : 0

  lifecycle {
    precondition {
      condition     = local.provision_github || trimspace(var.github_integration_name) != ""
      error_message = "enable_governance_codify requires github_integration_name (existing UI integration) or provision_github_integration with github_token."
    }
  }
}

module "github_integration" {
  count  = local.provision_github ? 1 : 0
  source = "../../modules/aios-integration-github"

  integration_name = trimspace(var.github_integration_name) != "" ? trimspace(var.github_integration_name) : "cloud-github"
  github_token     = var.github_token
  description      = "GitHub SCM integration for governance codify and IaC PR workflows (Nile-Staging)."
}

data "sg_guild_integration" "github" {
  count = local.use_existing_github ? 1 : 0
  name  = trimspace(var.github_integration_name)

  depends_on = [
    terraform_data.agent_stack_prerequisites,
    terraform_data.governance_codify_prerequisites,
  ]
}

data "sg_guild_integration" "aws" {
  count = var.enable_agent_stack ? 1 : 0
  name  = trimspace(var.aws_integration_name)

  depends_on = [terraform_data.agent_stack_prerequisites]
}

data "sg_remote_runner" "customer" {
  count = var.enable_agent_stack ? 1 : 0
  name  = trimspace(var.remote_runner_name)

  depends_on = [terraform_data.agent_stack_prerequisites]
}

module "aws_migrator" {
  count  = var.enable_agent_stack ? 1 : 0
  source = "../../modules/aios-agent-aws-migrator"

  policy_ids = {
    dangerous_ops = sg_policy.dangerous_ops.id
  }

  existing_github_integration_name = local.resolved_github_integration_name
  existing_aws_integration_name    = data.sg_guild_integration.aws[0].name
  existing_azure_integration_name  = trimspace(var.azure_integration_name)
  existing_gcp_integration_name    = trimspace(var.gcp_integration_name)
  extra_agent_integration_names    = []

  require_azure_live_plan = false
  require_gcp_live_plan   = false

  create_remote_runner          = false
  remote_runner_name            = data.sg_remote_runner.customer[0].name
  remote_runner_attach_to_agent = true
  # Walmart Guild rejects Generic/env vault secrets; pack is baked into the ACA
  # nile-factory-runner image (Stackgen-Runner), not synced via mothership.
  remote_runner_script_pack_sync_enabled = false
  remote_runner_secret_sync_enabled      = false

  azure_only_source_branch = var.azure_only_source_branch
  gcp_only_source_branch   = var.gcp_only_source_branch

  default_iac_repository_url = var.iac_repository_url
  default_branch             = var.default_branch
  enable_github_webhook      = false

  nile_rules_ref = "main"

  model_names             = local.resolved_model_names
  non_trivial_model_names = var.non_trivial_model_names
}

module "governance_codify" {
  count  = var.enable_governance_codify || var.enable_agent_stack ? 1 : 0
  source = "../../modules/aios-agent-governance-codify"

  existing_github_integration_name = local.resolved_github_integration_name
  default_source_repository_url    = "https://github.com/Walmart-StackGen/Governance-and-Policy.git"
  default_source_ref               = "main"
  default_target_repository_url    = "https://github.com/Walmart-StackGen/Nile-Factory.git"
  default_target_ref               = "main"
  default_base_branch              = "main"

  model_names = local.resolved_model_names
}
