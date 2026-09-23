# =============================================================================
# Deployment: greenfield (empty workspace bring-up)
# =============================================================================
# Stands up the AWS migrator agent in an empty StackGen workspace:
#   - Creates the customer IAM role (ReadOnlyAccess + Deny for workforce IAM/Athena/
#     key-pair APIs; app roles/policies remain readable for acquisition migrations)
#   - Wires the AWS + GitHub + Azure (Reader-only) Guild integrations, optional
#     GCP SA credentials, a dangerous-ops policy, and a self-registered remote runner.
#   - Creates runner ARM_* / GCP ADC vault secrets so azure-/gcp-iac-validate can
#     run live tofu plan (never apply) against destination clouds.
#   - Omits model_names by default so Guild resolves its built-in default
#     provider. When azure_openai_api_url + azure_openai_api_key are set,
#     registers an openai-compatible Azure OpenAI provider and attaches
#     var.azure_openai_models (explicit list; no defaults) to the agent.

locals {
  enable_gcp_live_plan = trimspace(var.gcp_credentials_json) != "" && trimspace(var.gcp_project_id) != ""
}

# Workspace AWS Vault config: bastion principal + stable external ID + ready trust policy.
data "sg_vault_aws_config" "workspace" {
  org_id = var.stackgen_project_id
}

# Customer-account role the Guild AWS MCP / cloud2code path assumes. Trust policy
# comes straight from the workspace Vault config so the bastion + external ID always match.
# Permissions: ReadOnlyAccess plus Deny for workforce IAM (users/groups/keys/SAML/OIDC),
# Athena, and EC2 key pairs. Application roles/policies stay readable so acquisition
# migrations capture custom permission surfaces (see deny-unmappable-aws-reads.json +
# default_cloud2code_exclude). Folded attribute types keep parent-service reads.
resource "aws_iam_role" "integration" {
  name               = var.role_name
  assume_role_policy = data.sg_vault_aws_config.workspace.trust_policy
  description        = "StackGen AWS migration discovery role (read-only; human IAM/Athena/key-pairs denied)."
}

resource "aws_iam_role_policy_attachment" "readonly" {
  role       = aws_iam_role.integration.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "deny_unmappable_source_reads" {
  name   = "${var.role_name}-deny-unmappable-reads"
  role   = aws_iam_role.integration.id
  policy = file("${path.module}/policies/deny-unmappable-aws-reads.json")
}

# AWS integration created inline so external_id lands in the secret metadata
# (the shared aios-integration-aws module does not carry external_id).
resource "sg_secret" "aws_vault" {
  name        = "${var.aws_integration_name}-vault"
  description = "AWS role-assumption credentials for ${var.aws_integration_name}."
  category    = "CloudProvider"
  subcategory = "aws"
  metadata = {
    aws_role_arn       = aws_iam_role.integration.arn
    aws_region         = var.aws_region
    AWS_DEFAULT_REGION = var.aws_region
    external_id        = data.sg_vault_aws_config.workspace.external_id
  }
}

resource "sg_guild_integration" "aws" {
  name           = var.aws_integration_name
  description    = "Read-only AWS cloud integration for discovery and plan hydration."
  type           = "aws"
  scope          = "PROJECT"
  secret_ref_ids = [sg_secret.aws_vault.id]
  enabled        = true

  image = {
    name = "ghcr.io/appcd-dev/stackgen-guild-integration-aws:main"
  }
}

module "github_integration" {
  source = "../../modules/aios-integration-github"

  integration_name = var.github_integration_name
  github_token     = var.github_token
}

# Azure Reader SP + Guild Azure MCP integration (local azurerm/azuread providers).
module "azure_integration" {
  source = "../../modules/aios-integration-azure"

  integration_name    = var.azure_integration_name
  description         = "Read-only Azure cloud integration for live tofu plan (no apply)."
  create_azure_reader = true
  app_display_name    = var.azure_reader_app_display_name
}

# Runner env secret uses ARM_* keys — Guild Azure vault uses client_id/tenant_id/…
# and remote-runner sync injects metadata keys as-is.
resource "sg_secret" "runner_azure_arm_env" {
  name        = "${var.azure_integration_name}-runner-arm-env"
  description = "ARM_* credentials for remote-runner live tofu plan (Reader SP; never used for apply)."
  category    = "CloudProvider"
  subcategory = "azure"
  metadata = {
    ARM_CLIENT_ID       = module.azure_integration.client_id
    ARM_CLIENT_SECRET   = module.azure_integration.client_secret
    ARM_TENANT_ID       = module.azure_integration.tenant_id
    ARM_SUBSCRIPTION_ID = module.azure_integration.subscription_id
    # Vault-shape aliases so validate can normalize either key set.
    client_id       = module.azure_integration.client_id
    client_secret   = module.azure_integration.client_secret
    tenant_id       = module.azure_integration.tenant_id
    subscription_id = module.azure_integration.subscription_id
  }
}

module "gcp_integration" {
  count  = local.enable_gcp_live_plan ? 1 : 0
  source = "../../modules/aios-integration-gcp"

  integration_name     = var.gcp_integration_name
  gcp_credentials_json = var.gcp_credentials_json
  gcp_project_id       = var.gcp_project_id
  gcp_region           = var.gcp_region
}

# Runner env secret: use generic subcategory so sync injects ADC JSON as env
# (typed `gcp` vault Resolve returns OAuth access_token, which tofu cannot use).
# Bound via typed slot `{ gcp = id }` — GetSecret uses this secret's subcategory.
resource "sg_secret" "runner_gcp_env" {
  count = local.enable_gcp_live_plan ? 1 : 0

  name        = "${var.gcp_integration_name}-runner-gcp-env"
  description = "GCP ADC credentials for remote-runner live tofu plan (never used for apply)."
  category    = "Provider"
  subcategory = "generic"
  metadata = {
    # Generic vault requires `value`; also expose ADC keys the validate stage reads.
    value                               = var.gcp_credentials_json
    GOOGLE_APPLICATION_CREDENTIALS_JSON = var.gcp_credentials_json
    GCP_PROJECT_ID                      = var.gcp_project_id
    GCP_REGION                          = var.gcp_region
    GOOGLE_CLOUD_PROJECT                = var.gcp_project_id
  }
}

resource "sg_policy" "dangerous_ops" {
  name        = "dangerous-ops"
  description = "Gate destructive or off-hours high-risk shell commands with HITL approval."
  type        = "logic"
  rego_source = file("${path.module}/policies/dangerous-ops.rego")
}

module "aws_migrator" {
  source = "../../modules/aios-agent-aws-migrator"

  policy_ids = {
    dangerous_ops = sg_policy.dangerous_ops.id
  }

  existing_github_integration_name = module.github_integration.integration_name
  existing_aws_integration_name    = sg_guild_integration.aws.name
  # Agent PUT currently fails on provider auto_extract (Guild API PARSING_ERROR).
  # Azure/GCP MCP attach is pending that fix; live plan uses runner env secrets below.
  # existing_azure_integration_name  = module.azure_integration.integration_name
  # existing_gcp_integration_name    = try(module.gcp_integration[0].integration_name, "")
  extra_agent_integration_names = []

  runner_azure_env_secret_id = sg_secret.runner_azure_arm_env.id
  require_azure_live_plan    = true

  runner_gcp_env_secret_id = local.enable_gcp_live_plan ? sg_secret.runner_gcp_env[0].id : ""
  require_gcp_live_plan    = local.enable_gcp_live_plan ? true : null

  create_remote_runner          = true
  remote_runner_attach_to_agent = true
  runner_git_token              = var.github_token
  remote_runner_labels = {
    "aws.accounts"  = var.aws_account_id
    "gitlab.host"   = "gitlab.com"
    "kube.contexts" = "in-cluster"
  }

  # Prior discovery split branch for azure-/gcp-only smoke (git ref name may be historical).
  azure_only_source_branch = var.azure_only_source_branch
  gcp_only_source_branch   = var.gcp_only_source_branch

  default_iac_repository_url = var.iac_repository_url
  default_branch             = var.default_branch
  enable_github_webhook      = false

  nile_rules_ref = "main"

  # Empty when Azure OpenAI is off or azure_openai_models is [] → Guild built-in default.
  model_names = local.enable_azure_openai ? [for m in var.azure_openai_models : m.name] : []
}

module "governance_codify" {
  source = "../../modules/aios-agent-governance-codify"

  existing_github_integration_name = module.github_integration.integration_name
  default_source_repository_url    = "https://github.com/Walmart-StackGen/Governance-and-Policy.git"
  default_source_ref               = "main"
  default_target_repository_url    = "https://github.com/Walmart-StackGen/Nile-Factory.git"
  default_target_ref               = "main"
  default_base_branch              = "main"
}
