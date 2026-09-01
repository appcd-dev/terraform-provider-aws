variable "stackgen_url" {
  description = "Base URL of the StackGen platform."
  type        = string
  default     = "https://walmart.cloud.stackgen.com"
}

variable "stackgen_token" {
  description = "StackGen personal access token."
  type        = string
  sensitive   = true
}

variable "stackgen_project_id" {
  description = "Target StackGen workspace (org/project) UUID."
  type        = string
}

variable "aws_region" {
  description = "AWS region embedded in the AWS integration vault secret and used by the AWS provider."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "Optional AWS named profile for the aws provider. Leave empty in CI (OIDC / env creds); locally you can set this or export AWS_PROFILE."
  type        = string
  default     = ""
}

variable "aws_account_id" {
  description = "AWS account ID for runner labels (aws.accounts). Set in gitignored tfvars — do not commit real account IDs."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must be a 12-digit AWS account ID (no placeholders)."
  }
}

variable "github_token" {
  description = "GitHub PAT (repo, read:org) for the GitHub integration and runner git push. Pass via TF_VAR_github_token."
  type        = string
  sensitive   = true
}

variable "role_name" {
  description = "IAM role name created in the target AWS account for the Guild AWS MCP integration to assume."
  type        = string
  default     = "stackgen-cloud-aws-readonly-tramlaw"
}

variable "aws_integration_name" {
  description = "Guild AWS cloud integration name (MCP tool prefix). Not tied to the aws-migrator agent."
  type        = string
  default     = "cloud-aws"
}

variable "github_integration_name" {
  description = "Guild GitHub cloud integration name (MCP tool prefix). Not tied to the aws-migrator agent."
  type        = string
  default     = "cloud-github"
}

variable "azure_integration_name" {
  description = "Guild Azure cloud integration name (MCP + vault secret). Not tied to the aws-migrator agent."
  type        = string
  default     = "cloud-azure"
}

variable "azure_subscription_id" {
  description = "Optional Azure subscription ID for the azurerm provider (defaults to the subscription from az login / env)."
  type        = string
  default     = ""
}

variable "azure_reader_app_display_name" {
  description = "Azure AD app display name for the Reader service principal created for live tofu plan."
  type        = string
  default     = "stackgen-cloud-azure-reader-walle"
}

variable "gcp_integration_name" {
  description = "Guild GCP cloud integration name (created when gcp_credentials_json + gcp_project_id are set). Not tied to the aws-migrator agent."
  type        = string
  default     = "cloud-gcp"
}

variable "gcp_credentials_json" {
  description = "GCP service account key JSON for live tofu plan. Empty skips GCP integration + require_gcp_live_plan."
  type        = string
  sensitive   = true
  default     = ""
}

variable "gcp_project_id" {
  description = "GCP project ID for live tofu plan (required with gcp_credentials_json)."
  type        = string
  default     = ""
}

variable "gcp_region" {
  description = "Default GCP region embedded in the runner/integration vault secret."
  type        = string
  default     = "us-central1"
}

variable "iac_repository_url" {
  description = "Repository that receives generated source/destination cloud IaC artifacts."
  type        = string
  default     = "https://github.com/Walmart-StackGen/Nile-Factory.git"
}

variable "default_branch" {
  description = "Base branch for generated IaC pull requests."
  type        = string
  default     = "main"
}

variable "azure_only_source_branch" {
  description = "Git branch with prior discovery IaC for the azure-only smoke workflow."
  type        = string
  # Minimal fixture for OPA/governance loop smoke (full discovery branches were deleted).
  default = "fixture/opa-gcp-source-mini"
}

variable "gcp_only_source_branch" {
  description = "Git branch with prior discovery IaC for the gcp-only smoke workflow."
  type        = string
  default     = "fixture/opa-gcp-source-mini"
}

variable "azure_openai_api_url" {
  description = "Azure OpenAI resource endpoint (e.g. https://<resource>.openai.azure.com). Empty skips Azure OpenAI provider/models."
  type        = string
  default     = ""
}

variable "azure_openai_api_key" {
  description = "Azure OpenAI API key. Empty (with empty URL) skips Azure OpenAI provider/models."
  type        = string
  sensitive   = true
  default     = ""
}

variable "azure_openai_api_version" {
  description = "Azure OpenAI API version stored as vault OPENAI_API_VERSION."
  type        = string
  default     = "2024-08-01-preview"
}

variable "azure_openai_provider_name" {
  description = "Guild model provider name for Azure OpenAI (provider_type = openai)."
  type        = string
  default     = "azure-openai"
}

variable "azure_openai_models" {
  description = "Explicit Azure OpenAI deployments to register when URL+key are set. Empty by default — no built-in models. model_id is the Azure deployment name."
  type = list(object({
    name          = string
    model_id      = string
    good_for_task = optional(string, "tool_calling")
  }))
  default = []
}
