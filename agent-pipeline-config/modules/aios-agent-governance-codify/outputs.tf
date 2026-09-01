output "agent_name" {
  description = "Governance codify architect agent name."
  value       = sg_agent.governance_codify_architect.name
}

output "workflow_name" {
  description = "On-demand governance-rules-codify workflow name."
  value       = sg_workflow.governance_rules_codify.name
}

output "github_integration_name" {
  description = "GitHub integration attached to the agent."
  value       = nonsensitive(local.resolved_github_integration_name)
}

output "sop_name" {
  description = "Governance rules codify SOP skill name."
  value       = local.sop_governance_codify_name
}

output "opa_codify_method_skill_name" {
  description = "Markdown to OPA codify method skill (rules-codify stage)."
  value       = local.opa_codify_method_name
}

output "evidence_checklist_name" {
  description = "Evidence checklist for governance-rules-codify runs."
  value       = sg_evidence_checklist.governance_rules_codify_evidence.name
}
