# 12. I want to…

Task-oriented navigation. Pick your goal, not a folder name.

| I want to… | Start here | Key files |
| --- | --- | --- |
| Understand what this repo does | [01. Mental model](01-mental-model.md) | `docs/`, `aws/`, `azure/`, `gcp/` |
| Learn StackGen / Nile jargon | [02. Glossary](02-glossary.md) | especially execute_series, script pack, emission |
| See who talks to whom | [03. Architecture](03-architecture.md) | `deployments/walle/` |
| Trace why a workflow stage failed | [11. Script and stage catalog](11-script-and-stage-catalog.md) → stage row → log | `$HOME/.<run_id>/.work/logs/<stage>.log` on runner |
| Know what the LLM does vs scripts | [05. LLM vs scripts](05-llm-vs-scripts.md) | `stage-runner.sh`, `*_iac_generate.py` |
| Change AWS→Azure mapping | [09. How to change things](09-how-to-change-things.md) | `mappings/aws-to-azure.json`, `azure_iac_generate.py` |
| Change AWS→GCP mapping | [09. How to change things](09-how-to-change-things.md) | `mappings/aws-to-gcp.json`, `gcp_iac_generate.py` |
| Bump the script pack after editing scripts | [09. How to change things](09-how-to-change-things.md) | `main.tf` `script_pack_version`, `preload-script-pack.sh`, then `make catalog` |
| Run script unit tests locally | `make test` from repo root | `scripts/test_*.py` |
| Bring up a greenfield StackGen workspace | [00. Quickstart](00-quickstart.md) | `agent-pipeline-config/deployments/walle/` |
| Start the remote runner | [08. Day-2 ops](08-day-2-ops.md), [runner/README](../runner/README.md) | `tofu output -raw remote_runner_cli_start_command` |
| Trigger a migration workflow | [08. Day-2 ops](08-day-2-ops.md) | intents: `aws-cloud-discovery`, `azure-migration-pr`, `gcp-migration-pr` |
| Review an Azure migration PR | [07. Reading Azure PRs](07-reading-azure-prs.md) | `azure/groups/`, `azure/artifacts/` |
| Review a GCP migration PR | [07b. Reading GCP PRs](07b-reading-gcp-prs.md) | `gcp/groups/`, `gcp/artifacts/` |
| Add or update governance Rego rules | [governance-codify README](../agent-pipeline-config/modules/aios-agent-governance-codify/README.md) | workflow `governance-rules-codify` |
| Understand living Nile governance at runtime | [04. Workflows & stages](04-workflows-and-stages.md) | `governance_conform.py`, Governance-and-Policy repo |
| Follow naming conventions for new resources | [NAMING.md](../agent-pipeline-config/modules/aios-agent-aws-migrator/NAMING.md) | agent=`aws-migrator-*`, cloud=`cloud-*` |
| Work with AI assistants in this repo | [AGENTS.md](../AGENTS.md) | repo root |

## Two Terraform worlds (do not mix them up)

| World | You `tofu apply` it? | Lives in |
| --- | --- | --- |
| **Pipeline config** | Yes (once per workspace) | `agent-pipeline-config/` |
| **Migration IaC** | No (humans review PRs; may apply later) | `aws/`, `azure/`, `gcp/` |

## Workflow name cheat sheet

| Intent (StackGen UI) | Also called (older docs) | What it does |
| --- | --- | --- |
| `aws-cloud-discovery` | `aws-migrator-discovery` | AWS scan → split → reverse-IaC → **AWS discovery PR** |
| `azure-migration-pr` | `aws-migrator-azure-only` | Azure destination from existing AWS split branch |
| `gcp-migration-pr` | `aws-migrator-gcp-only` | GCP destination from existing AWS split branch |
| `governance-rules-codify` | — | Governance markdown → `rules/` Rego PR |
