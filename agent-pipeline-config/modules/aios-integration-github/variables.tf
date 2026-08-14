variable "github_token" {
  description = <<-EOT
    GitHub personal access token (requires `repo`, `read:org` scopes). When set, this module
    creates a fresh `sg_secret` of category `SCM`/subcategory `github` and binds the integration
    to it. Mutually exclusive with `existing_secret_id` — set exactly one. Pass `""` (the
    default) when `existing_secret_id` is supplied instead.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "existing_secret_id" {
  description = <<-EOT
    Optional ID of a pre-existing `sg_secret` holding the GitHub PAT. When set, this module
    skips creating its own secret and binds the GitHub integration directly to the supplied
    secret. Use this when several agent modules share a single tenant-level PAT in Vault and
    you do not want a duplicate `sg_secret` per consumer. Mutually exclusive with
    `github_token` — set exactly one.

    The referenced secret SHOULD use category `SCM`, subcategory `github`, with metadata
    `{ provider = "github", token = <pat> }` to remain compatible with the Guild GitHub
    integration container's secret reader.
  EOT
  type        = string
  default     = ""
}

variable "integration_name" {
  type    = string
  default = "github-integration"
}

variable "description" {
  type    = string
  default = "GitHub SCM integration for repository operations, PRs, and code analysis"
}

variable "scope" {
  type    = string
  default = "PROJECT"
}

variable "enabled" {
  type    = bool
  default = true
}

variable "integration_image" {
  type    = string
  default = "ghcr.io/appcd-dev/stackgen-guild-integration-github:main"
}

variable "env" {
  description = <<-EOT
    Optional map of plain-text environment variables injected into the GitHub
    integration container at launch (StackGen provider >= 0.1.17). Use for
    non-sensitive overrides such as proxy URLs or feature toggles. Sensitive
    values should go through `sg_secret` and be referenced via
    `secret_ref_ids`.
  EOT
  type        = map(string)
  default     = {}
}
