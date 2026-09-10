output "agent_names" {
  description = "Names of agents created by this module."
  value = {
    aws_migrator_architect = sg_agent.aws_migrator_architect.name
  }
}

output "remote_runner_name" {
  description = "Resolved remote runner name (module default or var.remote_runner_name)."
  value       = module.remote_runner.runner_name
}

output "shell_tool_prefix" {
  description = "Remote runner tool prefix for execute_command|series|parallel|create_files (same as remote_runner_name)."
  value       = local.shell_tool_prefix
}

output "remote_runner_created" {
  description = "True when this apply registered sg_remote_runner (create_remote_runner = true)."
  value       = module.remote_runner.created
}

output "remote_runner_mothership_url" {
  description = "Mothership URL from provider stackgen_url when runner was created in this apply."
  value       = module.remote_runner.mothership_url
}

output "remote_runner_cli_start_command" {
  description = "aiden-runner start command when create_remote_runner is true."
  value       = module.remote_runner.cli_start_command
  sensitive   = true
}

output "remote_runner_helm_install_command" {
  description = "Helm install command when create_remote_runner is true."
  value       = module.remote_runner.helm_install_command
  sensitive   = true
}

output "remote_runner_cli_start_command_with_secrets" {
  description = "aiden-runner start command with secrets sync flags when vault bindings are configured."
  value       = module.remote_runner.cli_start_command_with_secrets
  sensitive   = true
}

output "remote_runner_secrets_bound" {
  description = "True when sg_remote_runner_secrets was applied (git/aws vault refs on the runner)."
  value       = module.remote_runner.runner_secrets_bound
}

output "remote_runner_typed_secret_refs" {
  description = "Typed vault secret bindings on the remote runner (github/aws slots, etc.)."
  value       = module.remote_runner.typed_secret_refs
  sensitive   = true
}

output "runner_git_env_secret_id" {
  description = "Vault secret ID for runner GIT_TOKEN sync (created or runner_git_env_secret_id input)."
  value       = local.runner_git_env_secret_id
  sensitive   = true
}

output "runner_aws_env_secret_id" {
  description = "Vault secret ID for runner AWS_* sync (created or runner_aws_env_secret_id input)."
  value       = local.runner_aws_env_secret_id
  sensitive   = true
}

output "runner_azure_env_secret_id" {
  description = "Vault secret ID for runner ARM_* sync (runner_azure_env_secret_id input)."
  value       = local.runner_azure_env_secret_id
  sensitive   = true
}

output "require_azure_live_plan" {
  description = "Whether azure-iac-validate fails closed when Azure credentials are missing."
  value       = local.require_azure_live_plan
}

output "runner_gcp_env_secret_id" {
  description = "Vault secret ID for runner GCP ADC sync (runner_gcp_env_secret_id input)."
  value       = local.runner_gcp_env_secret_id
  sensitive   = true
}

output "runner_script_pack_env_secret_id" {
  description = "Vault secret ID for SCRIPT_PACK_* runner sync (created or runner_script_pack_env_secret_id input)."
  value       = local.runner_script_pack_env_secret_id
  sensitive   = true
}

output "script_pack_tarball_url" {
  description = "Tarball URL written into the runner script-pack vault secret for mothership sync."
  value       = local.script_pack_tarball_url
}

output "require_gcp_live_plan" {
  description = "Whether gcp-iac-validate fails closed when GCP credentials are missing."
  value       = local.require_gcp_live_plan
}

output "workflow_names" {
  description = "Primary and secondary workflow names."
  value = {
    aws_migrator_discovery               = sg_workflow.aws_migrator_discovery.name
    aws_migrator_azure_only              = sg_workflow.aws_migrator_azure_only.name
    aws_migrator_gcp_only                = sg_workflow.aws_migrator_gcp_only.name
    aws_migrator_orphan_module_authoring = sg_workflow.aws_migrator_orphan_iac_module_authoring.name
  }
}

output "webhook_id" {
  description = "GitHub webhook id when enable_github_webhook is true; empty string otherwise."
  value       = var.enable_github_webhook ? sg_webhook.github_aws_migrator[0].id : ""
}

output "webhook_token" {
  description = "Webhook HMAC secret when enable_github_webhook is true."
  value       = var.enable_github_webhook ? sg_webhook.github_aws_migrator[0].token : ""
  sensitive   = true
}

output "webhook_trigger_endpoint" {
  description = "Non-sensitive `POST …/api/v1/webhooks/trigger` URL when `webhook_trigger_base_url` is set; empty string otherwise."
  value       = trimspace(var.webhook_trigger_base_url) == "" ? "" : "${trimsuffix(trimspace(var.webhook_trigger_base_url), "/")}/api/v1/webhooks/trigger"
}

output "webhook_ingress_payload_url" {
  description = "Full StackGen trigger URL with `apiKey` when `webhook_trigger_base_url` is set and `enable_github_webhook` produced a non-empty token; null otherwise."
  sensitive   = true
  value = (
    var.enable_github_webhook && trimspace(var.webhook_trigger_base_url) != "" && trimspace(sg_webhook.github_aws_migrator[0].token) != ""
    ) ? format(
    "%s/api/v1/webhooks/trigger?apiKey=%s%s",
    trimsuffix(trimspace(var.webhook_trigger_base_url), "/"),
    urlencode(sg_webhook.github_aws_migrator[0].token),
    trimspace(var.webhook_trigger_org_id) == "" ? "" : format("&orgId=%s", urlencode(trimspace(var.webhook_trigger_org_id)))
  ) : null
}

output "github_integration_name" {
  description = <<-EOT
    Name of the GitHub Guild integration the agent uses. Equals
    `var.existing_github_integration_name` when supplied; otherwise the
    module-provisioned `cloud-github[-<suffix>]` integration name.
  EOT
  value       = nonsensitive(local.resolved_github_integration_name)
}

output "aws_integration_name" {
  description = <<-EOT
    Name of the AWS Guild integration the agent uses. Equals
    `var.existing_aws_integration_name` when supplied; otherwise the
    module-provisioned `cloud-aws[-<suffix>]` integration name.
  EOT
  value       = nonsensitive(local.resolved_aws_integration_name)
}

output "script_pack_version" {
  description = <<-EOT
    Version of the tfstate decomposition script pack this module expects on the
    remote runner. Every pack file is sha256-gated, so the runner must be
    preloaded at this exact version; otherwise stages fail with
    `script_pack_error=preload_sha256_mismatch`.
  EOT
  value       = local.script_pack_version
}

output "script_pack_preload_dir" {
  description = <<-EOT
    Absolute directory on the remote runner where the script pack must be
    preloaded. Exposed so operators can preload without hand-deriving the path
    from the runner home and pack version.
  EOT
  value       = local.script_pack_preload_dir
}

output "remote_runner_image" {
  description = "Recommended GHCR image for the remote runner (script pack + opa baked in). Pin this instead of stock guild-aiden-runner."
  value       = local.nile_factory_runner_image
}

output "remote_runner_helm_image_sets" {
  description = "Helm --set overrides when upgrading aiden-runner to the Nile-Factory image (append to remote_runner_helm_install_command). Clears runner.allowedClis so aiden-runner 0.2.22 keeps its /usr/bin default."
  value       = "image.repository=${local.nile_factory_runner_image_repository} --set image.tag=${local.nile_factory_runner_image_tag} --set runner.allowedClis="
}

output "ingest_bootstrap_script" {
  description = <<-EOT
    Rendered `ingest-bootstrap.sh` that must be preloaded alongside the script
    pack. It is generated from module locals (including the pack sha gates), so
    it cannot be copied from the repository like the other pack files. Without
    this output, operators would have to reconstruct the rendered bootstrap by
    hand on every pack version bump.
  EOT
  value       = local.ingest_bootstrap_script
  sensitive   = true
}
