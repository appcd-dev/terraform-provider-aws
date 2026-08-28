# Documentation hub (start here)

These guides explain **cloud-migrator** for engineers working with StackGen, Guild agents, and AWS→Azure / AWS→GCP migration. Read in order the first time; jump by topic after that.

| # | Doc | When you need it |
| --- | --- | --- |
| 0 | [Quickstart](00-quickstart.md) | Clone → apply `walle` → start runner → first workflow |
| 1 | [Mental model](01-mental-model.md) | “What is this repo actually doing?” |
| 2 | [Glossary](02-glossary.md) | Acronyms and StackGen jargon |
| 3 | [Architecture](03-architecture.md) | Who talks to whom (StackGen, runner, GitHub, clouds) |
| 4 | [Workflows & stages](04-workflows-and-stages.md) | Discovery vs azure-only vs gcp-only; stage DAG |
| 5 | [LLM vs scripts](05-llm-vs-scripts.md) | What the model does vs what Python/bash does |
| 6 | [Catalog & generation](06-mapping-catalog-and-generation.md) | How AWS types become Azure/GCP HCL |
| 7 | [Reading Azure PRs](07-reading-azure-prs.md) | How to review an Azure migration PR |
| 7b | [Reading GCP PRs](07b-reading-gcp-prs.md) | How to review a GCP migration PR |
| 8 | [Day-2 ops](08-day-2-ops.md) | Apply, runner, script pack, trigger a run |
| 9 | [How to change things](09-how-to-change-things.md) | Safe edit checklist for catalog, pack, and workflow changes |
| 10 | [Remote runner FAQ](10-remote-runner-faq.md) | Image, registry, tags, K8s vs Docker, `--auto-discover`, ACA, sizing, FQDNs, tokens |

## Related READMEs (deeper / machine-facing)

| Path | Audience |
| --- | --- |
| [Root README](../README.md) | Quick start + path map |
| [Runner image](../runner/README.md) | Nile-Factory Dockerfile, GHCR tags, `docker run` |
| [agent-pipeline-config](../agent-pipeline-config/README.md) | Config layout |
| [deployments](../agent-pipeline-config/deployments/README.md) | Empty-workspace bring-up (`walle`) |
| [aios-agent-aws-migrator](../agent-pipeline-config/modules/aios-agent-aws-migrator/README.md) | Module contract, stages, evidence |
| [mappings](../agent-pipeline-config/modules/aios-agent-aws-migrator/mappings/README.md) | Azure catalog schema + emission |
| [mappings GCP](../agent-pipeline-config/modules/aios-agent-aws-migrator/mappings/README-gcp.md) | GCP catalog notes |
| [aios-integration-azure](../agent-pipeline-config/modules/aios-integration-azure/README.md) | Reader SP for Azure live plan |
| [aios-integration-gcp](../agent-pipeline-config/modules/aios-integration-gcp/README.md) | SA credentials for GCP live plan |
| [`aws/`](../aws/README.md) / [`azure/`](../azure/README.md) / [`gcp/`](../gcp/README.md) | What workflow PRs write into this repo |

## One-sentence product goal

Discover AWS, reverse-engineer Terraform, open an AWS split PR, then generate **review-candidate** Azure and/or GCP Terraform and open destination PRs — **never apply** the migrated destination resources from the agent.
