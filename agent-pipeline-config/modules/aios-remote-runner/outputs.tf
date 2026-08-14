output "runner_name" {
  description = "Guild remote runner name to pass to sg_agent.remote_runners."
  value       = local.runner_name
}

output "runner_id" {
  description = "Server-assigned runner ID."
  value       = local.runner_id
}

output "runner_status" {
  description = "Runner lifecycle status from Guild (online, offline, etc.)."
  value       = local.status
}

output "created" {
  description = "True when this apply registered a new sg_remote_runner (create_runner = true)."
  value       = var.create_runner
}

output "mothership_url" {
  description = "StackGen mothership base URL when runner was created in this apply; empty on lookup-only."
  value       = var.create_runner ? sg_remote_runner.this[0].mothership_url : ""
}

output "cli_start_command" {
  description = "Copy-paste aiden-runner start command when create_runner is true."
  value       = var.create_runner ? sg_remote_runner.this[0].cli_start_command : null
  sensitive   = true
}

output "helm_install_command" {
  description = "Copy-paste Helm install for aiden-runner when create_runner is true."
  value       = var.create_runner ? sg_remote_runner.this[0].helm_install_command : null
  sensitive   = true
}

output "runner_secrets_bound" {
  description = "True when this apply configured sg_remote_runner_secrets on the runner."
  value       = local.bind_secrets
}

output "typed_secret_refs" {
  description = "Typed vault bindings applied to the runner (echo of input when bound)."
  value       = local.bind_secrets ? var.typed_secret_refs : {}
}

output "sync_cli_args" {
  description = "Optional aiden-runner flags from sg_remote_runner_secrets (append to cli_start_command when non-empty)."
  value = (
    local.bind_secrets
    ? sg_remote_runner_secrets.this[0].sync_cli_args
    : ""
  )
}

output "cli_start_command_with_secrets" {
  description = "aiden-runner start command with sync_cli_args appended when secrets are bound."
  value = var.create_runner ? trimspace(join(" ", compact([
    sg_remote_runner.this[0].cli_start_command,
    local.bind_secrets ? sg_remote_runner_secrets.this[0].sync_cli_args : "",
  ]))) : null
  sensitive = true
}
