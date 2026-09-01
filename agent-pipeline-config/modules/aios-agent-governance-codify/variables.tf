variable "model_names" {
  description = "Optional ordered list of registered model names for the governance codify agent. Leave empty for Guild default."
  type        = list(string)
  default     = []
}

variable "existing_github_integration_name" {
  description = "Required Guild GitHub integration name (gh/git sidecar). This is the only integration the agent uses."
  type        = string

  validation {
    condition     = trimspace(var.existing_github_integration_name) != ""
    error_message = "existing_github_integration_name is required — wire module.github_integration.integration_name from the deployment."
  }
}

variable "default_source_repository_url" {
  description = "Default governance markdown source repo URL (read-only intake). Used when workflow input source_repository_url is omitted."
  type        = string
  default     = "https://github.com/Walmart-StackGen/Governance-and-Policy.git"
}

variable "default_source_ref" {
  description = "Default git ref for governance markdown in the source repo when source_ref input is omitted."
  type        = string
  default     = "main"
}

variable "default_target_repository_url" {
  description = "Default target repo URL for Rego rule packs and PRs when workflow input target_repository_url is omitted."
  type        = string
  default     = "https://github.com/Walmart-StackGen/Nile-Factory.git"
}

variable "default_target_ref" {
  description = "Default git ref to clone on the target repo before branching (usually main)."
  type        = string
  default     = "main"
}

variable "default_rules_output_dir" {
  description = "Default directory in the target repo for codified rule packs."
  type        = string
  default     = "rules"
}

variable "default_base_branch" {
  description = "Default PR base branch when base_branch input is omitted."
  type        = string
  default     = "main"
}

variable "github_check_name" {
  description = "GitHub Actions check name the rules-pr stage waits for before noting rules_codify_ok=true."
  type        = string
  default     = "rules-validate"
}

variable "name_suffix" {
  description = "Optional suffix appended to agent, workflow, and SOP names (e.g. tenant id)."
  type        = string
  default     = ""
}

variable "workflow_skill_refs" {
  description = "Optional extra skill refs per stage binding key (workflow::stage_id)."
  type        = map(list(string))
  default     = {}
}

variable "planner_max_tool_iterations" {
  description = "Max tool iterations for the governance-rules-codify workflow planner."
  type        = number
  default     = 96
}
