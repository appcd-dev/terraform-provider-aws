output "aws_role_arn" {
  description = "Customer-account IAM role the Guild AWS integration assumes."
  value       = aws_iam_role.integration.arn
}

output "aws_integration_name" {
  description = "Guild AWS integration name attached to the agent."
  value       = sg_guild_integration.aws.name
}

output "github_integration_name" {
  description = "Guild GitHub integration name attached to the agent."
  value       = module.github_integration.integration_name
}

output "azure_integration_name" {
  description = "Guild Azure (Reader) integration name attached to the agent."
  value       = module.azure_integration.integration_name
}

output "runner_azure_env_secret_id" {
  description = "Vault secret ID with ARM_* keys bound to the remote runner for live tofu plan."
  value       = sg_secret.runner_azure_arm_env.id
  sensitive   = true
}

output "gcp_integration_name" {
  description = "Guild GCP integration name when GCP live-plan credentials were provided; empty otherwise."
  value       = try(module.gcp_integration[0].integration_name, "")
}

output "runner_gcp_env_secret_id" {
  description = "Vault secret ID with GCP ADC keys bound to the remote runner for live tofu plan (empty when GCP disabled)."
  value       = try(sg_secret.runner_gcp_env[0].id, "")
  sensitive   = true
}

output "dangerous_ops_policy_id" {
  description = "dangerous-ops policy UUID passed to the agent module."
  value       = sg_policy.dangerous_ops.id
}

output "remote_runner_cli_start_command" {
  description = "Command to start the self-registered aiden-runner (runner must be online before workflows run)."
  value       = try(module.aws_migrator.remote_runner_cli_start_command_with_secrets, module.aws_migrator.remote_runner_cli_start_command, null)
  sensitive   = true
}

output "remote_runner_docker_start_command" {
  description = "Copy-paste command for starting the module-created remote runner with Docker or the aiden-runner CLI."
  value       = try(module.aws_migrator.remote_runner_cli_start_command_with_secrets, module.aws_migrator.remote_runner_cli_start_command, null)
  sensitive   = true
}

output "remote_runner_helm_install_command" {
  description = "Copy-paste Helm command for installing the module-created remote runner."
  value       = module.aws_migrator.remote_runner_helm_install_command
  sensitive   = true
}

output "script_pack_version" {
  description = "Script pack version the runner must be preloaded at."
  value       = module.aws_migrator.script_pack_version
}

output "script_pack_preload_dir" {
  description = "Directory on the runner where the script pack must be preloaded."
  value       = module.aws_migrator.script_pack_preload_dir
}

output "ingest_bootstrap_script" {
  description = "Rendered ingest-bootstrap.sh to preload alongside the script pack."
  value       = module.aws_migrator.ingest_bootstrap_script
  sensitive   = true
}
