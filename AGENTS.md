# AGENTS.md

Guide for engineers and AI assistants working in Nile-Factory (cloud-migrator).

## What this repo does

StackGen discovers live AWS resources, reverse-engineers Terraform under `aws/`, then generates review-candidate Azure and/or GCP Terraform under `azure/` and `gcp/`. Workflows open GitHub PRs. The agent never applies destination infrastructure.

You `tofu apply` **pipeline config** in `agent-pipeline-config/` to install agents into StackGen. You **review** (and humans may later apply) **migration IaC** in `aws/`, `azure/`, and `gcp/`.

## Start here

1. [docs/README.md](docs/README.md) — numbered guide hub
2. [docs/12-i-want-to.md](docs/12-i-want-to.md) — task-oriented navigation
3. [docs/11-script-and-stage-catalog.md](docs/11-script-and-stage-catalog.md) — stage → script traceability (run `make catalog` to regenerate)

## Jargon cheat sheet

| Term | Plain English |
| --- | --- |
| **execute_series** | Shell the LLM pastes verbatim; runs preloaded commands on the remote runner |
| **Script pack** | Versioned bash/Python copied to the runner at `~/.aws-migrator/script-pack/<version>/` |
| **Remote runner** | VM/pod (`aiden-runner`) that runs cloud2code, tofu, git, gh |
| **Mapping catalog** | JSON file mapping AWS Terraform types to Azure/GCP decisions |
| **Emission** | What the generator actually wrote (`full_scaffold`, `none`, …) — not the same as `status=mapped` |
| **Review-candidate** | Good enough for a PR review, not production-ready |
| **Living Nile governance** | Each run refreshes Governance-and-Policy docs and builds a run-specific validator |
| **Codify** | Offline workflow that turns governance markdown into Rego rules under `rules/` |
| **Conform** | Per-run check that generated IaC matches current governance docs |
| **AppStack** | StackGen resource grouping; destination-only runs must not create these |

Full list: [docs/02-glossary.md](docs/02-glossary.md).

## Do not confuse

- **Pipeline config** (`agent-pipeline-config/`) vs **migration IaC** (`aws/`, `azure/`, `gcp/`)
- **LLM orchestration** (paste execute_series, record notes) vs **deterministic scripts** (catalog + Python write HCL)
- **`docs/nile-governance/`** (human browse pin) vs **Governance-and-Policy on GitHub** (runtime source for conform)

## When editing scripts

1. Change files under `agent-pipeline-config/modules/aios-agent-aws-migrator/scripts/`
2. Bump `local.script_pack_version` in `main.tf` and matching `SCRIPT_PACK_VERSION` in `stage-runner.sh`
3. Run `make test`
4. Run `make catalog` and commit the updated catalog doc
5. Apply pipeline config and re-preload the script pack on the runner

Naming rules: [agent-pipeline-config/modules/aios-agent-aws-migrator/NAMING.md](agent-pipeline-config/modules/aios-agent-aws-migrator/NAMING.md).

## Invocation flow (4 layers)

```text
workflows_*.tf → stage_context.tf + *.tftpl → LLM execute_series
  → run-destination-stage.sh → stage-runner.sh cmd_* → Python helpers
```

If Azure/GCP HCL looks wrong, fix the **catalog or generator**, not the agent persona prompt first.

## Makefile targets

```bash
make test          # run script pack unit tests
make catalog       # regenerate docs/11-script-and-stage-catalog.md
make catalog-check # fail if catalog is stale (CI)
```
