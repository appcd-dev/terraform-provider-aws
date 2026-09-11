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
  default     = false
}

variable "enable_governance_codify" {
  description = "When true, installs governance-rules-codify agent + workflow (markdown → Rego PR). Does not require enable_agent_stack or a remote runner."
  type        = bool
  default     = false
}

variable "provision_github_integration" {
  description = "When true and github_token is set, Terraform creates the GitHub Guild integration instead of looking up an existing one by name."
  type        = bool
  default     = false
}

variable "github_token" {
  description = "GitHub PAT for provision_github_integration (repo + read:org). Pass via TF_VAR_github_token; do not commit."
  type        = string
  sensitive   = true
  default     = ""
}

variable "github_integration_name" {
  description = "GitHub Guild integration name — existing (lookup) or name to create when provision_github_integration is true. Default cloud-github when provisioning."
  type        = string
  default     = "cloud-github"
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
