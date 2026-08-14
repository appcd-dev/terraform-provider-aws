variable "azure_subscription_id" {
  description = "Azure subscription ID for the azurerm provider"
  type        = string
  default     = ""
}

variable "azure_reader_role_scope" {
  description = "Scope for Azure reader role assignments. Defaults to subscription."
  type        = string
  default     = ""
}

variable "create_azure_reader" {
  description = "Set to true to create the Azure reader application"
  type        = bool
  default     = true
}

variable "app_display_name" {
  description = "Display name for the Azure AD application"
  type        = string
  default     = "guild-azure-reader"
}

variable "integration_name" {
  type    = string
  default = "azure-production"
}

variable "description" {
  type    = string
  default = "Azure integration for autonomous SRE operations with Azure CLI"
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
  default = "ghcr.io/appcd-dev/stackgen-guild-integration-azure:main"
}

variable "existing_secret_id" {
  description = <<-EOT
    Optional pre-existing `sg_secret` ID to bind to this integration. When set,
    this module SKIPS provisioning the Azure AD service principal, role assignments,
    and `sg_secret` — it only creates the `sg_guild_integration` and binds it to
    the supplied secret. Useful when multiple modules share a single Azure
    credential (the secret must already exist as `CloudProvider`/`azure` shape).
  EOT
  type        = string
  default     = ""
}

variable "env" {
  description = <<-EOT
    Optional map of plain-text environment variables injected into the Azure
    integration container at launch (StackGen provider >= 0.1.17). Use for
    non-sensitive overrides such as proxy URLs, regional flags, or feature
    toggles. Sensitive values should go through `sg_secret` and be
    referenced via `secret_ref_ids`.
  EOT
  type        = map(string)
  default     = {}
}
