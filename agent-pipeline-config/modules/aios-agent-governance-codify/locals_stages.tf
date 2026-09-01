locals {
  governance_codify_stages = [
    {
      stage_id    = "rules-intake"
      description = "Dual-clone source (governance markdown) + target (rules/manifest); compute stale docs"
      note        = "Source: Governance-and-Policy governance/**/*.md. Target: Nile-Factory rules/manifest.json. Emit nile-codify-inventory/v1."
      required    = true
    },
    {
      stage_id    = "rules-codify"
      description = "OPA coordinator: parallel sub-agents per stale markdown; merge manifest on target"
      note        = "Fan-out create_agent per stale doc (or folder). Sub-agents write packs only; parent merges manifest."
      required    = true
    },
    {
      stage_id    = "rules-pr"
      description = "Open PR on target repo (Nile-Factory); poll until rules-validate GHA check succeeds"
      note        = "Do not merge. note(rules_codify_ok=true) and rules_pr_url only when required check is green."
      required    = true
    },
  ]
}
