# =============================================================================
# Deployment: walmart (Nile-Staging / customer-managed integrations)
# =============================================================================
# The customer creates GitHub/AWS/GCP Guild integrations, vault secrets, and
# the remote runner in the StackGen UI. This root only looks them up by name,
# attaches agent + workflows, and binds existing vault secrets to the runner
# typed github/aws/gcp slots. TF never creates cloud integrations, vault secrets, or
# registers a runner.
#
# enable_agent_stack = false applies only the dangerous-ops policy and optional
# Azure OpenAI models (the GitHub integration is still looked up at plan time).
# enable_governance_codify additionally installs governance-rules-codify
# (markdown → Rego PR) without the migrator agent stack.

locals {
  # Prefer explicit customer model names so apply does not wipe UI selections with [].
  resolved_model_names = length(compact(var.model_names)) > 0 ? compact(var.model_names) : (
    local.enable_azure_openai ? [for m in var.azure_openai_models : m.name] : []
  )

  # Typed gcp slot attached when an existing vault UUID is bound (e.g. the
  # vibe-gcp-deployment secret_ref — attach for sync even though it resolves
  # OAuth tokens, not ADC JSON).
  runner_gcp_attached      = var.enable_agent_stack && trimspace(var.runner_gcp_env_secret_id) != ""
  runner_gcp_env_secret_id = trimspace(var.runner_gcp_env_secret_id)
  # GitHub Guild vault secret (SCM metadata `token`) bound to the runner typed
  # github slot. Preflight aliases `token` → GIT_TOKEN/GH_TOKEN; do not create a
  # second secret.
  # github_secret_id is sensitive; the attached flag is only whether it is set.
  runner_github_attached      = var.enable_agent_stack && trimspace(nonsensitive(var.github_secret_id)) != ""
  runner_github_env_secret_id = trimspace(var.github_secret_id)
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
      condition     = trimspace(var.github_integration_name) != ""
      error_message = "enable_agent_stack requires github_integration_name (existing UI integration)."
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
      condition     = trimspace(var.github_integration_name) != ""
      error_message = "enable_governance_codify requires github_integration_name (existing UI integration)."
    }
  }
}

data "sg_guild_integration" "github" {
  count = var.enable_agent_stack || var.enable_governance_codify ? 1 : 0
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

data "sg_guild_integration" "gcp" {
  count = var.enable_agent_stack && trimspace(var.gcp_integration_name) != "" ? 1 : 0
  name  = trimspace(var.gcp_integration_name)

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
  existing_gcp_integration_name = (
    length(data.sg_guild_integration.gcp) > 0
    ? data.sg_guild_integration.gcp[0].name
    : trimspace(var.gcp_integration_name)
  )
  extra_agent_integration_names = []

  require_azure_live_plan = false
  # Live tofu plan stays optional: the only GCP vault secret bound here
  # (vibe-gcp-deployment secret_ref) resolves OAuth access tokens, not ADC JSON
  # (access_token ≠ ADC). gcp-iac-validate soft-skips the live plan until a
  # secret with GOOGLE_APPLICATION_CREDENTIALS_JSON metadata is bound instead.
  require_gcp_live_plan = false

  create_remote_runner          = false
  remote_runner_name            = data.sg_remote_runner.customer[0].name
  remote_runner_attach_to_agent = true
  # Pack is baked into the ACA nile-factory-runner image (Stackgen-Runner). Keep
  # SCRIPT_PACK_* generic vault sync off — Walmart Guild rejects Generic/env
  # secrets for that path. Git credentials come from the existing GitHub
  # integration vault secret (typed slot `github`). Without that binding,
  # nile-runner_gh / pack-entry / gh pr create fail with "populate GH_TOKEN"
  # even when the cloud-github MCP integration works. SCM metadata exposes
  # `token`; runner preflight aliases it to GIT_TOKEN/GH_TOKEN.
  remote_runner_script_pack_sync_enabled = false
  remote_runner_secret_sync_enabled      = true
  # Typed slot `github` → existing cloud-github vault secret (no new secret).
  runner_git_env_secret_id = local.runner_github_env_secret_id
  # Typed slot `aws` → AWS_ACCESS_KEY_ID/SECRET via vault resolve. Bind the
  # customer's pre-created vault secret (this root never inline-creates one).
  runner_aws_env_secret_id = var.runner_aws_env_secret_id
  runner_aws_region        = var.runner_aws_region
  # Typed slot `gcp` → GOOGLE_APPLICATION_CREDENTIALS_JSON via mothership sync.
  runner_gcp_env_secret_id = local.runner_gcp_env_secret_id

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

  existing_github_integration_name = data.sg_guild_integration.github[0].name
  default_source_repository_url    = "https://github.com/Walmart-StackGen/Governance-and-Policy.git"
  default_source_ref               = "main"
  default_target_repository_url    = "https://github.com/Walmart-StackGen/Nile-Factory.git"
  default_target_ref               = "main"
  default_base_branch              = "main"

  model_names = local.resolved_model_names
}
