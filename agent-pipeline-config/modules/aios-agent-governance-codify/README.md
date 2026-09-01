# aios-agent-governance-codify

Standalone Guild module: on-demand **governance-rules-codify** workflow that reads markdown from a **source** GitHub repo, writes Rego + conftest rule packs under `rules/` in a **target** repo, opens a PR on the target, and gates on target-repo GitHub Actions.

## Cross-repo model

| Role | Default | Clone dir |
| --- | --- | --- |
| **Source** (markdown) | [Governance-and-Policy](https://github.com/Walmart-StackGen/Governance-and-Policy) `governance/**/*.md` | `/tmp/governance-source` |
| **Target** (Rego + PR) | [Nile-Factory](https://github.com/Walmart-StackGen/Nile-Factory) `rules/` | `/tmp/governance-codify` |

## Design

- **OPA-first persona** — reads governance markdown, extracts obligations in `controls.json`, writes Rego v1 + tests + conftest fixtures.
- **Dedicated skill** — `governance-opa-codify-method` loaded in `rules-codify` with the per-doc codify loop.
- **GitHub integration only** — `gh` / `git` via the Guild GitHub sidecar. No remote runner.
- **Dual clone at intake** — source for reading policy markdown; target for manifest, writes, push, PR.
- **File writes via `create_files`** — Rego/JSON/YAML only on the **target** clone (absolute paths).
- **CI validation** — `opa test` and `conftest` run in the **target** repo (`.github/workflows/rules-validate.yml`).

## Usage

```hcl
module "governance_codify" {
  source = "../../modules/aios-agent-governance-codify"

  existing_github_integration_name = module.github_integration.integration_name
  default_source_repository_url    = "https://github.com/Walmart-StackGen/Governance-and-Policy.git"
  default_source_ref               = "main"
  default_target_repository_url    = "https://github.com/Walmart-StackGen/Nile-Factory.git"
  default_target_ref               = "main"
  default_base_branch              = "main"
}
```

## Trigger

Passive intent: `governance-rules-codify`

Optional inputs: `source_repository_url`, `source_ref`, `target_repository_url`, `target_ref`, `base_branch`, `rules_output_dir`, `force_recodify`.

## Stages

1. **rules-intake** — dual clone; inventory stale source markdown vs target `rules/manifest.json` (no Rego)
2. **rules-codify** — OPA expert: read each stale markdown, write `controls.json` + `policy.rego` + tests per doc
3. **rules-pr** — open PR on **target**; poll until `rules-validate` check green

## Related

- Living governance conform (per migration run): `aios-agent-aws-migrator` / `nile-governance-learn-and-conform-sop`
