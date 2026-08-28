# Quickstart

Get from a fresh clone to a **first migration PR** in this repo. For deeper background, continue with [mental model](01-mental-model.md).

## What you will have when done

1. OpenTofu applied the `walle` deployment into a StackGen workspace.  
2. An `aiden-runner` online with the aws-migrator script pack.  
3. A workflow run that opens PRs under `aws/`, `azure/`, and/or `gcp/`.

The agent **never applies** destination Terraform. PRs are for human review.

## Prerequisites (checklist)

| Need | Notes |
| --- | --- |
| OpenTofu ≥ 1.6 | Provider downloads from `releases.stackgen.com` |
| StackGen URL + PAT + workspace UUID | Put in **gitignored** `*.tfvars` only |
| AWS credentials | Create IAM role + read/write the deployment S3 state bucket |
| GitHub PAT (`repo` + `read:org`) | `export TF_VAR_github_token="$(gh auth token)"` |
| Docker (or Helm) | Start this repo's image `ghcr.io/walmart-stackgen/nile-factory-runner` after apply ([runner README](../runner/README.md)) |
| Optional: Azure Reader rights | Live `tofu plan` on generated Azure roots |
| Optional: GCP SA JSON | Live `tofu plan` on generated GCP roots |
| Optional: Azure OpenAI URL + key + models | Custom LLM provider; omit for Guild built-in default |

Never commit tokens, SA JSON, `backend.hcl`, or Helm values that embed runner tokens.

## 15-minute path (empty StackGen workspace)

```bash
cd agent-pipeline-config/deployments/walle

# 1. Local secrets (gitignored)
mkdir -p ../../tfvars
cat > ../../tfvars/walle.tfvars <<'EOF'
stackgen_url        = "https://walmart.cloud.stackgen.com"
stackgen_token      = "<STACKGEN_PAT>"
stackgen_project_id = "<WORKSPACE_UUID>"
aws_account_id      = "<AWS_ACCOUNT_ID>"
# Optional GCP live plan:
# gcp_project_id       = "<GCP_PROJECT_ID>"
# gcp_credentials_json = <<-EOT
# { ... service account JSON ... }
# EOT
# Optional Azure OpenAI (list deployments explicitly — no defaults):
# azure_openai_api_url = "https://<resource>.openai.azure.com"
# azure_openai_api_key = "<AZURE_OPENAI_KEY>"
# azure_openai_models = [
#   { name = "azure-gpt-4o", model_id = "gpt-4o", good_for_task = "tool_calling" },
# ]
EOF

# 2. Local S3 backend (gitignored) — copy example and replace placeholders
cp backend.hcl.example backend.hcl
# edit: bucket, key, region, profile for YOUR account

export AWS_PROFILE="<AWS_PROFILE>"
export TF_VAR_github_token="$(gh auth token)"

tofu init -backend-config=backend.hcl
tofu apply -input=false -var-file=../../tfvars/walle.tfvars

# 3. Start the remote runner (required)
# Prefer this repo's image (tools + script pack baked in):
#   ghcr.io/walmart-stackgen/nile-factory-runner:pack-20260813.27
# See runner/README.md. tofu output still has mothership URL + runner token.
tofu output -raw remote_runner_cli_start_command
# run that command with the Nile-Factory image; wait until the runner is online in StackGen UI
```

Full bring-up, CI wiring, and troubleshooting: [deployments README](../agent-pipeline-config/deployments/README.md).

## After apply — run a workflow

1. Confirm the remote runner is **online**.  
2. Confirm the runner image tag matches `script_pack_version` (rebuild after pack bumps). `kubectl cp` preload is only a hot-fix.  
3. In StackGen, start one of:

| Workflow | Use when |
| --- | --- |
| `aws-migrator-discovery` | Full path: discover AWS → split → reverse HCL → destination PRs |
| `aws-migrator-azure-only` | Retest Azure from an existing AWS split branch |
| `aws-migrator-gcp-only` | Retest GCP from an existing AWS split branch |

Discovery needs at least `aws_region` (for example `us-east-1`).

## Where PRs land in this repo

| Path | Contents |
| --- | --- |
| `aws/groups/<group_id>/` | Reverse-engineered AWS Terraform |
| `aws/artifacts/` | Manifests, split reports |
| `azure/groups/<group_id>/` | Catalog-driven Azure HCL |
| `gcp/groups/<group_id>/` | Catalog-driven GCP HCL |

How to review those PRs: [Azure](07-reading-azure-prs.md) · [GCP](07b-reading-gcp-prs.md).

## Already have a Demo Workspace?

Use [`examples/scenarios/aws-migrator`](../agent-pipeline-config/examples/scenarios/aws-migrator/) instead of `deployments/walle` — it **reuses** an existing runner, integrations, and policy instead of creating them.

## Security (do not skip)

- Keep `*.tfvars`, `backend.hcl`, and local Helm/runner value files out of git.  
- Prefer **Reader-only** Azure SP and least-privilege GCP SA for live plan.  
- Rotate any StackGen / cloud token that was pasted into chat or tickets.  
- Docs and examples use placeholders like `<AWS_ACCOUNT_ID>` — never paste real account IDs or secrets into committed files.

## Next reading

1. [Mental model](01-mental-model.md) — what the pipeline is doing  
2. [Workflows & stages](04-workflows-and-stages.md) — discovery vs destination-only DAG  
3. [Day-2 ops](08-day-2-ops.md) — pack preload, triggers, troubleshooting  
