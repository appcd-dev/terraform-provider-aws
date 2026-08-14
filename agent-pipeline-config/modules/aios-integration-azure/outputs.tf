output "integration_name" {
  value = nonsensitive(sg_guild_integration.azure.name)
}

output "integration_id" {
  value = sg_guild_integration.azure.id
}

output "secret_id" {
  description = "ID of the `sg_secret` (newly provisioned or pre-existing) bound to this integration."
  value       = local.secret_id
  sensitive   = true
}

output "reader_principal_id" {
  description = "Object ID of the reader service principal for role assignments (empty when binding to an existing secret)."
  value       = local.create_secret ? azuread_service_principal.guild_azure_reader[0].object_id : ""
}

output "azure_role_scope" {
  description = "Scope used for role assignments (empty when binding to an existing secret)."
  value       = local.azure_role_scope
}

output "client_id" {
  description = "Azure AD client ID (empty when binding to an existing secret)."
  value       = local.azure_reader_client_id
}

output "tenant_id" {
  description = "Azure AD tenant ID (empty when binding to an existing secret)."
  value       = local.tenant_id
  sensitive   = true
}

output "subscription_id" {
  description = "Azure subscription ID (empty when binding to an existing secret)."
  value       = local.subscription_id
}

output "client_secret" {
  description = "Azure AD application password (empty when binding to an existing secret)."
  value       = local.client_secret
  sensitive   = true
}
