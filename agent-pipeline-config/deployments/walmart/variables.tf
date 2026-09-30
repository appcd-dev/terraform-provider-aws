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

variable "enable_agent_stack" {
  description = "When false, apply only StackGen bootstrap resources (policy, optional models). When true, attach agent + workflows to customer-created integrations and remote runner."
  type        = bool
  default     = true
}

variable "enable_governance_codify" {
  description = "When true, installs governance-rules-codify agent + workflow (markdown → Rego PR). Does not require enable_agent_stack or a remote runner."
  type        = bool
  default     = false
}

variable "github_integration_name" {
  description = "Existing GitHub Guild integration name (required). Customer creates the integration in the StackGen UI."
  type        = string
  default     = "cloud-github"
}

variable "github_secret_id" {
  description = "Existing vault secret UUID bound to the GitHub integration. When enable_agent_stack is true, the same secret is attached to the remote runner typed github slot (SCM metadata `token` is aliased to GIT_TOKEN/GH_TOKEN by runner preflight). This root never creates the secret."
  type        = string
  sensitive   = true
  default     = ""
}

variable "aws_integration_name" {
  description = "Existing AWS Aiden integration name (required when enable_agent_stack is true)."
  type        = string
  default     = ""
}

variable "remote_runner_name" {
  description = "Existing remote runner name (required when enable_agent_stack is true)."
  type        = string
  default     = ""
}

variable "runner_aws_env_secret_id" {
  description = "Existing vault secret UUID bound to the nile-runner typed aws slot (AWS_ACCESS_KEY_ID/SECRET metadata)."
  type        = string
  default     = "59dfde2a-3980-56a5-81f8-bb9be5de5e33"
}

variable "runner_aws_region" {
  description = "AWS region written into runner sync context for discovery scans."
  type        = string
  default     = "us-east-1"
}

variable "azure_integration_name" {
  description = "Optional existing Azure Aiden integration name to attach to the agent."
  type        = string
  default     = ""
}

variable "gcp_integration_name" {
  description = "Optional existing GCP Aiden integration name to attach to the agent."
  type        = string
  default     = ""
}

variable "runner_gcp_env_secret_id" {
  description = "Existing vault secret UUID bound to the nile-runner typed gcp slot. A secret with GOOGLE_APPLICATION_CREDENTIALS_JSON (service_account key) metadata enables live tofu plan; the current vibe-gcp OAuth secret does not."
  type        = string
  default     = ""
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
  default     = "fixture/opa-gcp-source-mini"
}

variable "gcp_only_source_branch" {
  description = "Git branch with prior discovery IaC for the gcp-only smoke workflow."
  type        = string
  default     = "fixture/opa-gcp-source-mini"
}

variable "model_names" {
  description = "Existing Guild model names to attach to aws-migrator-architect (and governance-codify when enabled). Use customer-registered names from the agent Models tab. When empty and Azure OpenAI models are registered by this stack, those names are used; otherwise Guild defaults apply and an empty list can clear UI selections on apply."
  type        = list(string)
  default     = []
}

variable "non_trivial_model_names" {
  description = "Optional override passed to aws-migrator for paste-heavy sub-agents. When empty, model_names is filtered to drop efficiency-tier names (mini|flash|nano|haiku)."
  type        = list(string)
  default     = []
}

variable "azure_openai_api_url" {
  description = "Azure OpenAI resource endpoint. Empty skips Azure OpenAI provider/models."
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
  description = "Aiden model provider name for Azure OpenAI (provider_type = openai)."
  type        = string
  default     = "azure-openai"
}

variable "azure_openai_models" {
  description = "Explicit Azure OpenAI deployments to register when URL+key are set. Empty by default."
  type = list(object({
    name          = string
    model_id      = string
    good_for_task = optional(string, "tool_calling")
  }))
  default = []
}
