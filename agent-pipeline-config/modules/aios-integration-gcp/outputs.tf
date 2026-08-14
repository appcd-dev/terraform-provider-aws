output "integration_id" { value = sg_guild_integration.gcp.id }
output "integration_name" { value = nonsensitive(sg_guild_integration.gcp.name) }

output "secret_id" {
  description = "ID of the `sg_secret` bound to the GCP integration."
  value       = local.secret_id
  sensitive   = true
}
