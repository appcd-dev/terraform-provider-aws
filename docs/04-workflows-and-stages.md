# 4. Workflows and stages

## Primary workflows

| Workflow | Purpose |
| --- | --- |
| **Discovery / full pipeline** | Scan AWS → split → reverse-IaC → AWS PR → Azure destination + GCP destination (parallel) → final gate |
| **Azure-only** | Start from an existing AWS split branch → generate Azure → validate → Azure PR |
| **GCP-only** | Start from an existing AWS split branch → generate GCP → validate → GCP PR |

Exact resource names live in the module TF (`workflows_discovery.tf`, `workflows_azure_only.tf`, `workflows_gcp_only.tf`, `workflows_orphan.tf`). Names can include a `name_prefix` from the deployment.

## Destination-only stage story (simplified)

```text
start
  → source-fetch            # clone AWS split branch into work root
  → migration-blueprint     # catalog decisions + review-needed
  → iac-generate            # write azure/ or gcp/ groups
  → iac-validate            # fmt/validate + sampled live plan
  → iac-loop                # retry generate/validate until ok or terminal blocker
  → pr                      # open GitHub PR
  → *-only-final            # evidence
```

Loops exist when generate/validate fail. If the pack SHA is wrong or destination credentials are missing (and live plan is required), retries will not help until ops fix the runner.

## What each destination stage must leave behind

| Stage | Azure signals | GCP signals |
| --- | --- | --- |
| Generate | `azure_iac_generated=true`, `azure/groups/` | `gcp_iac_generated=true`, `gcp/groups/` |
| Validate | `azure_plan_status=…` | `gcp_plan_status=…` |
| PR | `azure_pr_url=…` | `gcp_pr_url=…` |
| Final | Azure evidence checklist | GCP evidence checklist |

## Discovery stages (high level)

1. **Discover** — `cloud2code` / AWS inventory → monolith state  
2. **Split** — logical groups + registry  
3. **Reverse-IaC** — HCL per group; AWS plan ≈ no drift  
4. **AWS PR** — push `aws/` tree  
5. **Azure path** (parallel with GCP + orphans) — fetch → blueprint → generate → validate → PR  
6. **GCP path** (parallel) — same shape under `gcp/`  
7. **Final gate** — waits on Azure final + GCP final + orphans secondary

## Where stages are defined

| File | Contents |
| --- | --- |
| `workflows_discovery.tf` | Discovery / full AWS + destination paths |
| `workflows_azure_only.tf` | Azure-only path |
| `workflows_gcp_only.tf` | GCP-only path |
| `workflows_orphan.tf` | Orphan / cleanup style flows |
| `locals_azure_stages.tf` / `locals_gcp_stages.tf` | Shared stage metadata |
| `spawn_contracts.tf` | How stages spawn runner work |
| `templates/*.tftpl` | Embedded series scripts and prompts |

## Operator tip

When a run fails, open the Guild **execution watch** page (or export a debug ZIP) and find:

1. Which **stage** last succeeded  
2. Whether the failure is **preload / credentials / catalog / LLM loop**  
3. The **notes** map (often clearer than chat)

See also [day-2 ops](08-day-2-ops.md) and [reading Azure](07-reading-azure-prs.md) / [reading GCP](07b-reading-gcp-prs.md) PRs.
