# GCP destination artifacts

This tree is **generated review-candidate GCP IaC**, not apply-ready landing zones.

GCP-only (or full-pipeline) stages write:

| Path | Contents |
| --- | --- |
| `groups/<group_id>/` | Per-group OpenTofu roots from the GCP mapping catalog + generator |
| `artifacts/` | Blueprint, validation report, emission summaries |

Before you merge or demo “success,” read **[How to read destination PRs](../docs/07-reading-azure-prs.md)** and **[Reading GCP PRs](../docs/07b-reading-gcp-prs.md)** — especially `emission` vs `mapped` and sampled live plan (`success:sample:N/M`).

Background: [catalog & generation](../docs/06-mapping-catalog-and-generation.md), [LLM vs scripts](../docs/05-llm-vs-scripts.md).
