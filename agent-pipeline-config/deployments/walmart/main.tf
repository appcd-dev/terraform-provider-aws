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

  # Runner typed slot `gcp`: create a generic vault secret from inline SA JSON
  # (typed CloudProvider/gcp Resolve returns OAuth tokens tofu cannot use as ADC).
  # nonsensitive(): presence checks must not taint booleans/outputs with SA JSON sensitivity.
  create_runner_gcp_env = (
    var.enable_agent_stack
    && nonsensitive(trimspace(var.gcp_credentials_json) != "")
    && trimspace(var.gcp_project_id) != ""
  )
  # Plan-time known (do not inspect sg_secret.*.id here).
  enable_gcp_live_plan = local.create_runner_gcp_env || (
    var.enable_agent_stack && trimspace(var.runner_gcp_env_secret_id) != ""
  )
  runner_gcp_env_secret_id = local.create_runner_gcp_env ? sg_secret.runner_gcp_env[0].id : trimspace(var.runner_gcp_env_secret_id)
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

data "sg_guild_integration" "gcp" {
  count = var.enable_agent_stack && trimspace(var.gcp_integration_name) != "" ? 1 : 0
  name  = trimspace(var.gcp_integration_name)

  depends_on = [terraform_data.agent_stack_prerequisites]
}

resource "terraform_data" "runner_gcp_secret_input" {
  count = var.enable_agent_stack ? 1 : 0

  lifecycle {
    precondition {
      condition = !(
        trimspace(var.gcp_credentials_json) != "" && trimspace(var.runner_gcp_env_secret_id) != ""
      )
      error_message = "Set either gcp_credentials_json (+ gcp_project_id) or runner_gcp_env_secret_id, not both."
    }
    precondition {
      condition = (
        trimspace(var.gcp_credentials_json) == ""
        || trimspace(var.gcp_project_id) != ""
      )
      error_message = "gcp_credentials_json requires gcp_project_id for the runner GCP vault secret."
    }
  }
}

# Typed slot `gcp` on nile-runner → GOOGLE_APPLICATION_CREDENTIALS_JSON for live tofu plan.
# subcategory=generic: CloudProvider/gcp (and Provider/gcp) vaults require type=service_account
# and Resolve may return OAuth tokens. Generic keeps flat ADC env keys for tofu.
# Pass a real service_account JSON via TF_VAR_gcp_credentials_json for live plan.
resource "sg_secret" "runner_gcp_env" {
  count = local.create_runner_gcp_env ? 1 : 0

  name        = "${coalesce(trimspace(var.gcp_integration_name), "cloud-gcp")}-runner-gcp-env"
  description = "GCP ADC credentials for nile-runner live tofu plan (never used for apply)."
  category    = "Provider"
  subcategory = "generic"
  metadata = {
    value                               = var.gcp_credentials_json
    GOOGLE_APPLICATION_CREDENTIALS_JSON = var.gcp_credentials_json
    GCP_PROJECT_ID                      = var.gcp_project_id
    GCP_REGION                          = var.gcp_region
    GOOGLE_CLOUD_PROJECT                = var.gcp_project_id
  }

  depends_on = [terraform_data.runner_gcp_secret_input]
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
  existing_gcp_integration_name = (
    length(data.sg_guild_integration.gcp) > 0
    ? data.sg_guild_integration.gcp[0].name
    : trimspace(var.gcp_integration_name)
  )
  extra_agent_integration_names = []

  require_azure_live_plan = false
  # Live GCP plan needs a service_account key JSON in Provider/generic vault metadata.
  # gcloud authorized_user ADC is rejected by Provider/gcp vaults and does not sync
  # reliably into GOOGLE_APPLICATION_CREDENTIALS_JSON on this runner. Keep live plan
  # off until TF_VAR_gcp_credentials_json is a real SA key; static validate still runs.
  require_gcp_live_plan = false

  create_remote_runner          = false
  remote_runner_name            = data.sg_remote_runner.customer[0].name
  remote_runner_attach_to_agent = true
  # Pack is baked into the ACA nile-factory-runner image (Stackgen-Runner). Keep
  # SCRIPT_PACK_* generic vault sync off — Walmart Guild rejects Generic/env
  # secrets for that path. Git credentials MUST sync: without them nile-runner_gh /
  # pack-entry / gh pr create fail with "populate GH_TOKEN" even when the
  # cloud-github MCP integration works.
  remote_runner_script_pack_sync_enabled = false
  remote_runner_secret_sync_enabled      = true
  # Same PAT as cloud-github integration; typed slot `github` → GIT_TOKEN/GH_TOKEN
  # on the runner via mothership secret sync (memory-only).
  runner_git_token = var.github_token
  # Typed slot `aws` → AWS_ACCESS_KEY_ID/SECRET via vault resolve.
  # Prefer inline nile-factory keys (account 366938945728) when TF_VAR_* are set;
  # otherwise bind an existing vault secret. Module forbids setting both.
  runner_aws_access_key_id     = var.runner_aws_access_key_id
  runner_aws_secret_access_key = var.runner_aws_secret_access_key
  runner_aws_env_secret_id = (
    trimspace(var.runner_aws_access_key_id) != "" && trimspace(var.runner_aws_secret_access_key) != ""
  ) ? "" : var.runner_aws_env_secret_id
  runner_aws_region = var.runner_aws_region
  # Typed slot `gcp` → GOOGLE_APPLICATION_CREDENTIALS_JSON via mothership sync.
  runner_gcp_env_secret_id = local.runner_gcp_env_secret_id

  azure_only_source_branch = var.azure_only_source_branch
  gcp_only_source_branch   = var.gcp_only_source_branch

  default_iac_repository_url = var.iac_repository_url
  default_branch             = var.default_branch
  enable_github_webhook      = false

  nile_rules_ref = "fix/walmart-runner-git-secret-sync"

  model_names             = local.resolved_model_names
  non_trivial_model_names = var.non_trivial_model_names

  depends_on = [terraform_data.runner_gcp_secret_input]
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
