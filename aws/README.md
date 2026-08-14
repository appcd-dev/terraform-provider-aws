# AWS source artifacts

This tree is **migration IaC output**, not the agent pipeline config.

Workflow PRs (discovery / reverse-IaC stages) write:

| Path | Contents |
| --- | --- |
| `groups/<group_id>/` | One OpenTofu/Terraform root per logical AWS shard |
| `artifacts/` | Split manifests, quality reports, mapping notes |

**Do not** hand-edit these as the source of truth for demos — re-run discovery or open a follow-up PR from the agent. For how this fits the pipeline, see [docs/01-mental-model.md](../docs/01-mental-model.md) and [docs/04-workflows-and-stages.md](../docs/04-workflows-and-stages.md).
