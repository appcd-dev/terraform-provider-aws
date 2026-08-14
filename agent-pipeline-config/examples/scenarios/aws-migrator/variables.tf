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
  description = "Resolved Demo Workspace UUID."
  type        = string
  default     = "62e29120-d230-4d4c-ba0d-3426e887d697"
}

variable "name_suffix" {
  description = "Optional suffix for all workflow resources."
  type        = string
  default     = ""
}

variable "github_integration_name" {
  description = "Existing GitHub Guild integration name to attach."
  type        = string
  default     = "github-integration"
}

variable "aws_integration_name" {
  description = "Existing AWS Guild integration name to attach."
  type        = string
  default     = "stackgen-sandbox"
}

variable "remote_runner_name" {
  description = "Existing remote runner name to attach to the agent."
  type        = string
  default     = "demo-runner"
}

variable "extra_agent_integration_names" {
  description = "Additional existing integrations to preserve on the AWS-to-Azure architect agent."
  type        = list(string)
  default     = ["predictive-servicenow-cmdb-servicenow-demo"]
}

variable "dangerous_ops_policy_id" {
  description = "Existing dangerous-ops policy UUID in Demo Workspace."
  type        = string
  default     = "6aa4e036-5233-4678-b740-c6b0f588ed0f"
}

variable "default_iac_repository_url" {
  description = "Default repository that receives generated source/destination cloud IaC artifacts."
  type        = string
  default     = "https://github.com/Walmart-StackGen/Nile-Factory.git"
}

variable "default_branch" {
  description = "Base branch for generated IaC pull requests."
  type        = string
  default     = "main"
}

variable "runner_git_token" {
  description = "GitHub token synced into demo-runner for git push and gh pr create against cloud-migrator."
  type        = string
  default     = ""
  sensitive   = true
}

variable "model_names" {
  description = "Existing Demo Workspace model names to expose to the workflow agent."
  type        = list(string)
  default = [
    "anthropic-se-testing-claude-opus-4-7",
    "anthropic-se-testing-claude-opus-4-6",
    "anthropic-se-testing-claude-sonnet-4-6",
    "openai-arunav-gpt-5.5-pro",
    "openai-arunav-gpt-5.5",
    "openai-arunav-gpt-5.4",
    "longhorizon",
    "reasoning",
    "planning",
    "tool-calling",
    "terminal",
  ]
}

variable "non_trivial_model_names" {
  description = "Optional override for script/MCP-heavy sub-agents."
  type        = list(string)
  default = [
    "anthropic-se-testing-claude-opus-4-7",
    "anthropic-se-testing-claude-opus-4-6",
    "anthropic-se-testing-claude-sonnet-4-6",
    "openai-arunav-gpt-5.5-pro",
    "openai-arunav-gpt-5.5",
    "openai-arunav-gpt-5.4",
    "longhorizon",
    "reasoning",
    "planning",
    "tool-calling",
    "terminal",
  ]
}
