variable "gcp_credentials_json" {
  description = "GCP service account key JSON. Used to write the auto-created secret. Empty when `existing_secret_id` is supplied."
  type        = string
  sensitive   = true
  default     = ""
}
variable "gcp_project_id" {
  description = "GCP project ID. Used to write the auto-created secret. Empty when `existing_secret_id` is supplied."
  type        = string
  default     = ""
}
variable "gcp_region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}
variable "existing_secret_id" {
  description = <<-EOT
    Optional ID of a pre-existing `sg_secret` holding GCP service account
    credentials. When set, this module skips creating its own secret and
    binds the integration directly to the supplied secret. Mutually exclusive
    with `gcp_credentials_json` — set exactly one.
  EOT
  type        = string
  default     = ""
}
variable "integration_name" {
  type    = string
  default = "gcp-production"
}
variable "integration_image" {
  type    = string
  default = "ghcr.io/appcd-dev/stackgen-guild-integration-gcp:main"
}
variable "name_prefix" {
  type    = string
  default = ""
}

variable "env" {
  description = <<-EOT
    Optional map of plain-text environment variables injected into the GCP
    integration container at launch (StackGen provider >= 0.1.17). Use for
    non-sensitive overrides such as proxy URLs, regional flags, or feature
    toggles. Sensitive values should go through `sg_secret` and be
    referenced via `secret_ref_ids`.
  EOT
  type        = map(string)
  default     = {}
}
