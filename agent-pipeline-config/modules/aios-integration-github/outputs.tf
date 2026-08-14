output "integration_name" {
  value = nonsensitive(sg_guild_integration.github.name)
}

output "integration_id" {
  value = sg_guild_integration.github.id
}

output "secret_id" {
  description = "ID of the `sg_secret` bound to the GitHub integration. Equals `var.existing_secret_id` when supplied, otherwise the newly-created secret's ID. Marked sensitive because the provider treats `sg_secret.id` as sensitive — pass it through with the same flag downstream."
  value       = local.secret_id
  sensitive   = true
}
