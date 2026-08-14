# Azure destination artifacts

This tree is **generated review-candidate Azure IaC**, not apply-ready landing zones.

Azure-only (or full-pipeline) stages write:

| Path | Contents |
| --- | --- |
| `groups/<group_id>/` | Per-group OpenTofu roots from the mapping catalog + generator |
| `artifacts/` | Blueprint, validation report, emission summaries |

Before you merge or demo “success,” read **[How to read Azure PRs](../docs/07-reading-azure-prs.md)** — especially `emission` vs `mapped` and sampled live plan (`success:sample:N/M`).

Background: [catalog & generation](../docs/06-mapping-catalog-and-generation.md), [LLM vs scripts](../docs/05-llm-vs-scripts.md).
