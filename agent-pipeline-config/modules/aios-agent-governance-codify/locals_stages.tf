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
      description = "Open PR on target repo (Nile-Factory); CI wait+self-heal until rules-validate green"
      note        = "Do not merge. Repair CI failures (scaffold, Rego, manifest) up to ci_repair_max_iterations."
      required    = true
    },
  ]
}
