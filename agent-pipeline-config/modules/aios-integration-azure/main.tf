terraform {
  required_version = ">= 1.5"
  required_providers {
    sg = {
      source  = "releases.stackgen.com/stackgen/stackgen"
      version = ">= 0.1.39, < 0.2.0"
    }
    azuread = { source = "hashicorp/azuread", version = "~> 2.47" }
    azurerm = { source = "hashicorp/azurerm", version = "~> 3.85" }
  }
}

# =============================================================================
# Azure Integration Module (Reader only)
# =============================================================================
# Creates an Azure AD service principal with Reader role, stores credentials
# in Vault, and provisions a containerized Azure CLI MCP integration.
# Does NOT assign Storage Account Key Operator — live plan uses Reader only.

locals {
  create_secret = trimspace(var.existing_secret_id) == ""
  secret_id     = local.create_secret ? sg_secret.azure_vault[0].id : var.existing_secret_id
}

data "azurerm_subscription" "current" {
  count = local.create_secret ? 1 : 0
}
data "azuread_client_config" "current" {
  count = local.create_secret ? 1 : 0
}

data "azuread_application" "existing_reader" {
  count        = local.create_secret && !var.create_azure_reader ? 1 : 0
  display_name = var.app_display_name
}

locals {
  _subscription_id       = local.create_secret ? data.azurerm_subscription.current[0].id : ""
  _client_object_id      = local.create_secret ? data.azuread_client_config.current[0].object_id : ""
  azure_role_scope       = local.create_secret ? (var.azure_reader_role_scope != "" ? var.azure_reader_role_scope : local._subscription_id) : ""
  azure_reader_app_id    = local.create_secret ? (var.create_azure_reader ? azuread_application.guild_azure_reader[0].id : data.azuread_application.existing_reader[0].id) : ""
  azure_reader_client_id = local.create_secret ? (var.create_azure_reader ? azuread_application.guild_azure_reader[0].client_id : data.azuread_application.existing_reader[0].client_id) : ""
  tenant_id              = local.create_secret ? data.azuread_client_config.current[0].tenant_id : ""
  subscription_id        = local.create_secret ? data.azurerm_subscription.current[0].subscription_id : ""
  client_secret          = local.create_secret ? azuread_application_password.guild_azure_reader[0].value : ""
}

resource "azuread_application" "guild_azure_reader" {
  count        = local.create_secret && var.create_azure_reader ? 1 : 0
  display_name = var.app_display_name
  owners       = [local._client_object_id]
}

resource "azuread_service_principal" "guild_azure_reader" {
  count        = local.create_secret ? 1 : 0
  client_id    = local.azure_reader_client_id
  use_existing = true
  owners       = [local._client_object_id]
}

resource "azuread_application_password" "guild_azure_reader" {
  count          = local.create_secret ? 1 : 0
  application_id = local.azure_reader_app_id
  display_name   = "guild-sre-readonly"
}

resource "azurerm_role_assignment" "guild_reader" {
  count                = local.create_secret ? 1 : 0
  scope                = local.azure_role_scope
  role_definition_name = "Reader"
  principal_id         = azuread_service_principal.guild_azure_reader[0].object_id
}

resource "sg_secret" "azure_vault" {
  count       = local.create_secret ? 1 : 0
  name        = "${var.integration_name}-vault"
  description = "Azure service principal credentials (Reader role)"
  category    = "CloudProvider"
  subcategory = "azure"
  metadata = {
    client_id       = local.azure_reader_client_id
    tenant_id       = local.tenant_id
    client_secret   = local.client_secret
    subscription_id = local.subscription_id
  }
}

resource "sg_guild_integration" "azure" {
  name           = var.integration_name
  description    = var.description
  type           = "azure"
  scope          = var.scope
  secret_ref_ids = [local.secret_id]
  enabled        = var.enabled

  image = {
    name = var.integration_image
  }

  env = length(var.env) > 0 ? var.env : null
}
