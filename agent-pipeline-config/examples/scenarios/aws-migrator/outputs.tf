output "workspace" {
  description = "Resolved deployment target."
  value = {
    name = "Demo Workspace"
    id   = var.stackgen_project_id
    url  = var.stackgen_url
  }
}

output "reused_assets" {
  description = "Existing workspace assets reused by this deployment."
  value = {
    remote_runner = {
      name   = data.sg_remote_runner.demo.name
      status = data.sg_remote_runner.demo.status
    }
    github_integration = data.sg_guild_integration.github.name
    aws_integration    = data.sg_guild_integration.aws.name
    dangerous_ops_id   = var.dangerous_ops_policy_id
  }
}

output "agent_names" {
  description = "Names of agents deployed by the AWS-to-Azure IaC module."
  value       = module.aws_migrator.agent_names
}

output "workflow_names" {
  description = "Names of workflows deployed by the AWS-to-Azure IaC module."
  value       = module.aws_migrator.workflow_names
}

output "remote_runner_secrets_bound" {
  description = "True when the module bound its script-pack secret to the existing remote runner."
  value       = nonsensitive(module.aws_migrator.remote_runner_secrets_bound)
}

output "remote_runner_docker_start_command" {
  description = "Copy-paste command for starting the module-created remote runner with Docker or the aiden-runner CLI. This is null when the scenario reuses an existing runner."
  value       = module.aws_migrator.remote_runner_cli_start_command_with_secrets
  sensitive   = true
}

output "remote_runner_helm_install_command" {
  description = "Copy-paste Helm command for installing the module-created remote runner. This is null when the scenario reuses an existing runner."
  value       = module.aws_migrator.remote_runner_helm_install_command
  sensitive   = true
}
