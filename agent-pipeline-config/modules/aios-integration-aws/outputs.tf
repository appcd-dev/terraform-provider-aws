output "integration_name" {
  description = "Registered name of the AWS integration"
  value       = nonsensitive(sg_guild_integration.aws.name)
}

output "integration_id" {
  description = "ID of the AWS integration"
  value       = sg_guild_integration.aws.id
}

output "secret_id" {
  description = "ID of the `sg_secret` bound to the AWS integration. Equals `var.existing_secret_id` when supplied, otherwise the newly-created secret's ID."
  value       = local.secret_id
  sensitive   = true
}

output "secret_name" {
  description = "Name of the AWS vault secret when this module created it. Empty string when `existing_secret_id` was supplied."
  value       = local.create_secret ? sg_secret.aws_vault[0].name : ""
}
