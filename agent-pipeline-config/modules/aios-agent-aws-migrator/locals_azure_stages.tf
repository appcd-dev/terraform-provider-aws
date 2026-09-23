# Shared Azure pipeline stage metadata used by discovery and azure-only workflows.
locals {
  azure_pipeline_core_stages = [
    {
      stage_id    = "azure-migration-blueprint"
      description = "Read fetched AWS groups and emit a best-effort Azure migration blueprint"
      note        = "Script-first. Writes azure/artifacts/migration-blueprint.json and review-needed.md."
      required    = true
    },
    {
      stage_id    = "azure-iac-generate"
      description = "Generate best-effort Azure Terraform roots under azure/groups/<group_id>/"
      note        = "Script-first. Uses the default no-approval Azure migration profile."
      required    = true
    },
    {
      stage_id    = "azure-iac-validate"
      description = "Run Azure IaC fmt, validate, optional tests, optional lint, and live tofu plan when credentials are configured"
      note        = "Script-first. Live tofu plan required when require_azure_live_plan is set; never tofu apply. Record azure_plan_status + plan counts. Runs in parallel with azure-iac-harden."
      required    = true
    },
    {
      stage_id    = "azure-iac-harden"
      description = "Parallel lint/security pass: tflint, checkov/tfsec/trivy when present, mechanical autofix into azure/groups"
      note        = "Script-first. DAG-parallel with azure-iac-validate after generate. Autofixes land in the same Azure PR; residual findings in azure/artifacts/harden-findings.md."
      required    = true
    },
    {
      stage_id    = "azure-iac-governance-conform"
      description = "Refresh living Nile governance docs, derive a per-resource decision tree, author a validator, and re-verify Azure IaC"
      note        = "LLM-led. DAG-parallel with validate/harden after generate. Runtime fetch of Governance-and-Policy (not the optional submodule pin). Remediates OPA denies until azure_iac_governance_ok=true; residuals still documented in the PR TODO."
      required    = true
    },
    {
      stage_id    = "azure-iac-loop"
      description = "Retry Azure generation and validation until generated Azure IaC is valid or a terminal blocker is emitted"
      note        = "loop_stage only. Re-enters azure-iac-generate until a conclusive validate result (azure_iac_validation_ok true|false) or terminal runner blocker — not forever on validation_ok=false."
      required    = false
    },
    {
      stage_id    = "azure-iac-governance-loop"
      description = "Retry Azure governance conform until every resource is Priority-1-conformant or a terminal blocker is emitted"
      note        = "loop_stage only. Re-enters azure-iac-governance-conform until azure_iac_governance_ok=true or blocked:governance_docs_unavailable / opa_unavailable / generation_missing (max iterations still advances to azure-pr)."
      required    = false
    },
    {
      stage_id    = "azure-pr"
      description = "Push azure/ artifacts to the target IaC repo and open an Azure migration PR"
      note        = "Script-first. Fresh branch starting with azure/<workflow_run_id>; waits for validate-loop, harden, AND governance-loop. Always opens when prior stages conclude; documents governance/OPA residuals in TODO.md when ok=false."
      required    = true
    },
  ]
}
