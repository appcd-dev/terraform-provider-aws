# =============================================================================
# Deployment: walmart (Nile-Staging / customer-managed integrations)
# =============================================================================
# Phase 1 (enable_agent_stack = false): StackGen-only bootstrap — dangerous-ops
# policy and optional Azure OpenAI models. No AWS/Azure CLI creds required.
#
# Phase 2 (enable_agent_stack = true): attach agent + workflows to integrations
# and a remote runner the customer creates in the StackGen UI. TF never creates
# cloud integrations or registers a runner.

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
      condition     = trimspace(var.github_integration_name) != ""
      error_message = "enable_agent_stack requires github_integration_name — customer must create the GitHub integration in StackGen UI first."
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

data "sg_guild_integration" "github" {
  count = var.enable_agent_stack ? 1 : 0
  name  = trimspace(var.github_integration_name)

  depends_on = [terraform_data.agent_stack_prerequisites]
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

  existing_github_integration_name = data.sg_guild_integration.github[0].name
  existing_aws_integration_name    = data.sg_guild_integration.aws[0].name
  existing_azure_integration_name  = trimspace(var.azure_integration_name)
  existing_gcp_integration_name    = trimspace(var.gcp_integration_name)
  extra_agent_integration_names    = []

  require_azure_live_plan = false
  require_gcp_live_plan   = false

  create_remote_runner          = false
  remote_runner_name            = data.sg_remote_runner.customer[0].name
  remote_runner_attach_to_agent = true

  azure_only_source_branch = var.azure_only_source_branch
  gcp_only_source_branch   = var.gcp_only_source_branch

  default_iac_repository_url = var.iac_repository_url
  default_branch             = var.default_branch
  enable_github_webhook      = false

  nile_rules_ref = "f8f6f171a0a15c195954c53c330e15df2af6aa99_20260827033726"

  model_names = local.enable_azure_openai ? [for m in var.azure_openai_models : m.name] : []
}

module "governance_codify" {
  count  = var.enable_agent_stack ? 1 : 0
  source = "../../modules/aios-agent-governance-codify"

  existing_github_integration_name = data.sg_guild_integration.github[0].name
  default_source_repository_url    = "https://github.com/Walmart-StackGen/Governance-and-Policy.git"
  default_source_ref               = "main"
  default_target_repository_url    = "https://github.com/Walmart-StackGen/Nile-Factory.git"
  default_target_ref               = "main"
  default_base_branch              = "main"
}
