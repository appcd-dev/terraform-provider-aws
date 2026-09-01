output "stackgen_project_id" {
  description = "StackGen workspace UUID targeted by this deployment."
  value       = var.stackgen_project_id
}

output "enable_agent_stack" {
  description = "Whether agent + workflows were applied (phase 2)."
  value       = var.enable_agent_stack
}

output "dangerous_ops_policy_id" {
  description = "dangerous-ops policy UUID passed to the agent module in phase 2."
  value       = sg_policy.dangerous_ops.id
}

output "agent_name" {
  description = "AWS migrator architect agent name (empty until enable_agent_stack is true)."
  value       = try(module.aws_migrator[0].agent_name, null)
}

output "discovery_workflow_name" {
  description = "Primary discovery workflow name (empty until enable_agent_stack is true)."
  value       = try(module.aws_migrator[0].discovery_workflow_name, null)
}

output "script_pack_version" {
  description = "Script pack version the customer runner must preload (empty until phase 2)."
  value       = try(module.aws_migrator[0].script_pack_version, null)
}

output "script_pack_preload_dir" {
  description = "Directory on the runner where the script pack must be preloaded (empty until phase 2)."
  value       = try(module.aws_migrator[0].script_pack_preload_dir, null)
}

output "governance_codify_workflow_name" {
  description = "Governance codify workflow name (empty until enable_agent_stack is true)."
  value       = try(module.governance_codify[0].workflow_name, null)
}

output "next_steps" {
  description = "Human-readable checklist for what to do after this apply."
  value = var.enable_agent_stack ? trimspace(<<-EOT
    Phase 2 applied. Confirm the remote runner is online in StackGen UI, script pack version matches script_pack_version output, then start aws-migrator-discovery.
  EOT
  ) : trimspace(<<-EOT
    Phase 1 complete. Customer must create GitHub + AWS integrations and register a remote runner in StackGen UI, then set github_integration_name, aws_integration_name, remote_runner_name in tfvars and enable_agent_stack = true before re-applying.
  EOT
  )
}
