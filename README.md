# cloud-migrator

Private repository for StackGen AWS → Azure / GCP IaC migration: the agent pipeline that discovers AWS, reverse-engineers Terraform, maps resources to destination clouds, and opens PRs back into this repo.

**New to this repo?** Start with **[docs/00-quickstart.md](docs/00-quickstart.md)**, then the guide hub: **[docs/](docs/README.md)** (mental model, glossary, LLM vs scripts, how to read destination PRs, day-2 ops).

## What lives where

| Path | Purpose |
| --- | --- |
| [`docs/`](docs/) | Technical guides for the migration pipeline ([quickstart](docs/00-quickstart.md) first) |
| [`agent-pipeline-config/`](agent-pipeline-config/) | OpenTofu modules, runner script pack, and deployment roots that install the agent into a StackGen workspace |
| [`agent-pipeline-config/deployments/`](agent-pipeline-config/deployments/) | **Empty-workspace bring-up** — creates IAM role, integrations, policy, remote runner, agent, and workflows |
| [`agent-pipeline-config/examples/scenarios/aws-migrator/`](agent-pipeline-config/examples/scenarios/aws-migrator/) | Demo Workspace root that **reuses** existing integrations/runner/policy |
| [`aws/`](aws/) | Source-cloud Terraform and split artifacts written by workflow PRs |
| [`azure/`](azure/) | Destination-cloud IaC written by the Azure migration phase |
| [`gcp/`](gcp/) | Destination-cloud IaC written by the GCP migration phase |

## Quick start (empty StackGen workspace)

Use a deployment root when the target workspace has no integrations, remote runner, or models yet. The stock path is `walle`:

```bash
cd agent-pipeline-config/deployments/walle

# 1. Credentials (tfvars are gitignored — copy from a local template, never commit tokens)
cat > ../../tfvars/walle.tfvars <<'EOF'
stackgen_url        = "https://walmart.cloud.stackgen.com"
stackgen_token      = "<STACKGEN_PAT>"
stackgen_project_id = "<WORKSPACE_UUID>"
aws_account_id      = "<AWS_ACCOUNT_ID>"
EOF

# 2. Apply (AWS profile must reach the account that owns the S3 state bucket + IAM role)
export AWS_PROFILE="<AWS_PROFILE>"
export TF_VAR_github_token="$(gh auth token)"   # needs repo + read:org
cp backend.hcl.example backend.hcl              # gitignored; edit placeholders for your account
tofu init -backend-config=backend.hcl
tofu apply -input=false -var-file=../../tfvars/walle.tfvars

# 3. Start the remote runner (required before any workflow run)
tofu output -raw remote_runner_cli_start_command
# paste/run that Docker or aiden-runner CLI command; wait until the runner shows online
```

Full prerequisites, troubleshooting (including stale state locks), and how to clone the deployment for another workspace: **[deployments README](agent-pipeline-config/deployments/README.md)**.

## After apply — run a migration

1. Confirm the remote runner is **online** in the StackGen UI.
2. Start workflow `aws-migrator-discovery` with at least `aws_region` (for example `us-east-1`).
3. For faster destination-only retests (skips AWS discovery/split), use `aws-migrator-azure-only` or `aws-migrator-gcp-only`.

Workflow PRs land here:

- `aws/groups/<group_id>/` — reverse-engineered AWS Terraform roots
- `aws/artifacts/` — manifests, split quality reports, mapping notes
- `azure/groups/<group_id>/` — generated Azure equivalents (mapping catalog driven)
- `gcp/groups/<group_id>/` — generated GCP equivalents (mapping catalog driven)

Module behavior, script-pack preload, and workflow inputs: [`aios-agent-aws-migrator` README](agent-pipeline-config/modules/aios-agent-aws-migrator/README.md).

## Two ways to deploy

| Root | When to use |
| --- | --- |
| [`deployments/<name>/`](agent-pipeline-config/deployments/) | Empty workspace — creates AWS IAM role, Guild AWS + GitHub integrations, `dangerous-ops` policy, self-registered remote runner, agent + workflows. Uses Guild’s **built-in default model** (no model registry required). |
| [`examples/scenarios/aws-migrator/`](agent-pipeline-config/examples/scenarios/aws-migrator/) | Workspace that already has a runner, GitHub/AWS integrations, and a `dangerous-ops` policy (Demo Workspace pattern). |

## Requirements (summary)

- OpenTofu ≥ 1.6 and StackGen provider configured for the target URL
- AWS credentials that can create an IAM role and use the deployment’s S3 state backend
- GitHub PAT with `repo` + `read:org` (`TF_VAR_github_token`)
- StackGen PAT + workspace UUID in a local `*.tfvars` file (gitignored)
- Docker (or Helm) to run `aiden-runner` after apply
