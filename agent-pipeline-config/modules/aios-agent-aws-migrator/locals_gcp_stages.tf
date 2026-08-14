# Shared GCP pipeline stage metadata used by discovery and gcp-only workflows.
locals {
  gcp_pipeline_core_stages = [
    {
      stage_id    = "gcp-migration-blueprint"
      description = "Read fetched AWS groups and emit a best-effort GCP migration blueprint"
      note        = "Script-first. Writes gcp/artifacts/migration-blueprint.json and review-needed.md."
      required    = true
    },
    {
      stage_id    = "gcp-iac-generate"
      description = "Generate best-effort GCP Terraform roots under gcp/groups/<group_id>/"
      note        = "Script-first. Uses the default no-approval GCP migration profile."
      required    = true
    },
    {
      stage_id    = "gcp-iac-validate"
      description = "Run GCP IaC fmt, validate, optional tests, optional lint, and live tofu plan when credentials are configured"
      note        = "Script-first. Live tofu plan required when require_gcp_live_plan is set; never tofu apply. Record gcp_plan_status + plan counts. Runs in parallel with gcp-iac-harden."
      required    = true
    },
    {
      stage_id    = "gcp-iac-harden"
      description = "Parallel lint/security pass: tflint, checkov/tfsec/trivy when present, mechanical autofix into gcp/groups"
      note        = "Script-first. DAG-parallel with gcp-iac-validate after generate. Autofixes land in the same GCP PR; residual findings in gcp/artifacts/harden-findings.md."
      required    = true
    },
    {
      stage_id    = "gcp-iac-loop"
      description = "Retry GCP generation and validation until generated GCP IaC is valid or a terminal blocker is emitted"
      note        = "loop_stage only. Re-enters gcp-iac-generate until a conclusive validate result (gcp_iac_validation_ok true|false) or terminal runner blocker — not forever on validation_ok=false."
      required    = false
    },
    {
      stage_id    = "gcp-pr"
      description = "Push gcp/ artifacts to the target IaC repo and open an GCP migration PR"
      note        = "Script-first. Fresh branch starting with gcp/<workflow_run_id>; waits for validate-loop AND harden so lint/security fixes are in the same PR."
      required    = true
    },
  ]
}
