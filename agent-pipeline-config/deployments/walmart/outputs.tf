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

output "script_pack_tarball_url" {
  description = "Tarball URL the runner script-pack vault secret points at (empty until phase 2)."
  value       = try(module.aws_migrator[0].script_pack_tarball_url, null)
}

output "script_pack_preload_dir" {
  description = "Directory on the runner where the script pack must be preloaded (empty until phase 2)."
  value       = try(module.aws_migrator[0].script_pack_preload_dir, null)
}

output "enable_governance_codify" {
  description = "Whether governance-rules-codify was applied."
  value       = var.enable_governance_codify || var.enable_agent_stack
}

output "github_integration_name" {
  description = "Resolved GitHub integration name."
  value = var.enable_agent_stack || var.enable_governance_codify ? nonsensitive(
    data.sg_guild_integration.github[0].name
  ) : ""
}

output "governance_codify_workflow_name" {
  description = "Governance codify workflow name (empty until enable_governance_codify or enable_agent_stack)."
  value       = try(module.governance_codify[0].workflow_name, null)
}

output "governance_codify_agent_name" {
  description = "Governance codify architect agent name."
  value       = try(module.governance_codify[0].agent_name, null)
}

output "runner_github_attached" {
  description = "True when nile-runner typed github slot is bound to the existing GitHub integration vault secret."
  value       = var.enable_agent_stack ? local.runner_github_attached : false
}

output "runner_gcp_env_secret_id" {
  description = "Vault secret UUID bound to nile-runner typed gcp slot (empty when no GCP secret is wired)."
  value       = var.enable_agent_stack ? local.runner_gcp_env_secret_id : ""
}

output "runner_gcp_attached" {
  description = "True when nile-runner typed gcp slot has a vault secret (integration OAuth or SA-key ADC)."
  value       = var.enable_agent_stack ? local.runner_gcp_attached : false
}

output "require_gcp_live_plan" {
  description = "Whether gcp-iac-validate requires live tofu plan. False here: the bound vibe-gcp vault secret resolves OAuth tokens, not ADC JSON."
  value       = false
}

output "next_steps" {
  description = "Human-readable checklist for what to do after this apply."
  value = var.enable_agent_stack ? trimspace(<<-EOT
    Phase 2 applied. Confirm the remote runner is online in StackGen UI and typed secrets sync (${local.runner_github_attached ? "github/" : ""}aws${local.runner_gcp_attached ? "/gcp" : ""}). ${local.runner_github_attached ? "GitHub integration vault secret is bound to the runner typed github slot." : "To attach GitHub credentials to the runner, set github_secret_id and re-apply."} Script pack version must match script_pack_version output. ${local.runner_gcp_attached ? "GCP typed slot is attached; the live tofu plan stays soft until a vault secret with GOOGLE_APPLICATION_CREDENTIALS_JSON metadata (service_account key) is bound to the runner instead of the vibe-gcp OAuth secret." : "To attach GCP to the runner, set runner_gcp_env_secret_id and re-apply."} Then start aws-migrator-discovery or gcp-migration-pr.
  EOT
    ) : (var.enable_governance_codify ? trimspace(<<-EOT
    Governance codify applied. In StackGen UI start workflow governance-rules-codify (passive intent: governance-rules-codify) to test markdown → Rego PR generation.
  EOT
      ) : trimspace(<<-EOT
    Phase 1 complete. Customer must create GitHub + AWS integrations and register a remote runner in StackGen UI, then set github_integration_name, aws_integration_name, remote_runner_name in tfvars and enable_agent_stack = true before re-applying.
  EOT
  ))
}
