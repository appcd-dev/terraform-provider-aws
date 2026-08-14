variable "name" {
  description = "Guild remote runner name (sg_remote_runner.name). Used for create and for data.sg_remote_runner lookup."
  type        = string

  validation {
    condition     = trimspace(var.name) != ""
    error_message = "name must be a non-empty remote runner name."
  }
}

variable "create_runner" {
  description = <<-EOT
    When true, registers a new `sg_remote_runner` (StackGen provider >= 0.1.25). The runner connects outbound to
    mothership (`provider stackgen_url`) — suitable for on-prem / VPC / firewall-restricted environments.
    When false, only looks up an existing runner by `name` at plan time.
  EOT
  type        = bool
  default     = false
}

variable "description" {
  description = "Description for the runner when `create_runner` is true. Ignored on lookup-only mode."
  type        = string
  default     = "Aiden remote runner for Guild tool execution behind the customer firewall (outbound-only to mothership)."
}

variable "labels" {
  description = "Optional labels on the runner when `create_runner` is true (affinity routing)."
  type        = map(string)
  default     = {}
}

variable "typed_secret_refs" {
  description = <<-EOT
    Vault secret UUIDs keyed by subcategory (`aws`, `github`, `azure`, `gcp`, `kubernetes`, …).
    When non-empty and `bind_runner_secrets` is true, applies `sg_remote_runner_secrets` so
    mothership sync pushes flat env keys from vault metadata to aiden-runner (memory-only).
    Secret metadata must use env var names (e.g. `GIT_TOKEN`, `AWS_ACCESS_KEY_ID`) — not SCM
    integration shapes (`token` alone).
  EOT
  type        = map(string)
  default     = {}
}

variable "generic_secret_ref_ids" {
  description = "Generic vault secret UUIDs merged into runner env at sync time."
  type        = list(string)
  default     = []
}

variable "bind_runner_secrets" {
  description = "When true and `typed_secret_refs` or `generic_secret_ref_ids` is non-empty, manages `sg_remote_runner_secrets` on the runner."
  type        = bool
  default     = true
}

variable "secrets_sync_interval_seconds" {
  description = "Poll interval hint for aiden-runner `--secrets-sync-interval` (default 60). Non-default values surface in `sync_cli_args` output."
  type        = number
  default     = 60

  validation {
    condition     = var.secrets_sync_interval_seconds >= 15 && var.secrets_sync_interval_seconds <= 3600
    error_message = "secrets_sync_interval_seconds must be between 15 and 3600."
  }
}
