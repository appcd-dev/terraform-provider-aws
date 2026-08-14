variable "aws_role_arn" {
  description = <<-EOT
    AWS IAM Role ARN the AWS Guild integration assumes via Vault. When set,
    this module creates a fresh `sg_secret` of category `CloudProvider`,
    subcategory `aws` with the role ARN + region in metadata. Mutually
    exclusive with `existing_secret_id` — set exactly one.
  EOT
  type        = string
  default     = ""
}

variable "aws_region" {
  description = "Default AWS region. Embedded in the auto-created secret when `aws_role_arn` is supplied; ignored when `existing_secret_id` is set."
  type        = string
  default     = "us-east-1"
}

variable "existing_secret_id" {
  description = <<-EOT
    Optional ID of a pre-existing `sg_secret` holding AWS role-assume metadata.
    When set, this module skips creating its own secret and binds the AWS
    integration directly to the supplied secret. Use this when multiple agent
    modules share the same tenant-level AWS read role. Mutually exclusive with
    `aws_role_arn` — set exactly one.

    The referenced secret SHOULD use category `CloudProvider`, subcategory
    `aws`, with metadata `{ aws_role_arn = ..., aws_region = ..., AWS_DEFAULT_REGION = ... }`
    so the Guild AWS integration container's secret reader picks up the right
    credentials.
  EOT
  type        = string
  default     = ""
}

variable "integration_name" {
  description = "Name of the Guild integration resource"
  type        = string
  default     = "aws-production"
}

variable "description" {
  description = "Description for the integration"
  type        = string
  default     = "AWS Integration for autonomous SRE operations using assume role"
}

variable "scope" {
  description = "Integration scope (PROJECT or ORGANIZATION)"
  type        = string
  default     = "PROJECT"
}

variable "enabled" {
  description = "Whether the integration is enabled"
  type        = bool
  default     = true
}

variable "integration_image" {
  description = "Container image for the AWS MCP integration"
  type        = string
  default     = "ghcr.io/appcd-dev/stackgen-guild-integration-aws:main"
}

variable "env" {
  description = <<-EOT
    Optional map of plain-text environment variables injected into the AWS
    integration container at launch (StackGen provider >= 0.1.17). Use for
    non-sensitive overrides such as proxy URLs, regional flags, or feature
    toggles. Sensitive values should still go through `sg_secret` and be
    referenced via `secret_ref_ids`.
  EOT
  type        = map(string)
  default     = {}
}
