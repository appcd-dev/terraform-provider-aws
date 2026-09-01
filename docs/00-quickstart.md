# Quickstart

Get from a fresh clone to a **first migration PR** in this repo. For deeper background, continue with [mental model](01-mental-model.md).

## What you will have when done

1. OpenTofu applied into a StackGen workspace (`walmart` or `greenfield` deployment).  
2. An `aiden-runner` online with the aws-migrator script pack.  
3. A workflow run that opens PRs under `aws/`, `azure/`, and/or `gcp/`.

The agent **never applies** destination Terraform. Destination PRs open only after living Nile governance re-verification (`*_iac_governance_ok=true`). PRs are for human review.

## Which deployment?

| Path | When |
| --- | --- |
| [`deployments/walmart/`](../agent-pipeline-config/deployments/walmart/) | Customer creates integrations + runner in StackGen UI (Nile-Staging). Start here for Walmart. |
| [`deployments/greenfield/`](../agent-pipeline-config/deployments/greenfield/) | You own AWS/Azure creds and TF creates IAM, integrations, and runner. |
| [`examples/scenarios/aws-migrator/`](../agent-pipeline-config/examples/scenarios/aws-migrator/) | Reuse existing Demo Workspace assets. |

## Walmart path (customer-managed integrations)

Phase 1 — StackGen policy only (no AWS/Azure CLI):

```bash
cd agent-pipeline-config/deployments/walmart

mkdir -p ../../tfvars
cat > ../../tfvars/walmart.tfvars <<'EOF'
stackgen_url        = "https://walmart.cloud.stackgen.com"
stackgen_token      = "<STACKGEN_PAT>"
stackgen_project_id = "<WORKSPACE_UUID>"
enable_agent_stack  = false
EOF

tofu init
tofu apply -input=false -var-file=../../tfvars/walmart.tfvars
```

Phase 2 — after customer creates GitHub + AWS integrations and a remote runner, fill exact names in tfvars, set `enable_agent_stack = true`, re-apply. Full checklist: [walmart-customer-handoff.md](walmart-customer-handoff.md).

## Greenfield path (empty workspace you own)

```bash
cd agent-pipeline-config/deployments/greenfield

mkdir -p ../../tfvars
cat > ../../tfvars/greenfield.tfvars <<'EOF'
stackgen_url        = "https://walmart.cloud.stackgen.com"
stackgen_token      = "<STACKGEN_PAT>"
stackgen_project_id = "<WORKSPACE_UUID>"
aws_account_id      = "<AWS_ACCOUNT_ID>"
EOF

cp backend.hcl.example backend.hcl
export AWS_PROFILE="<AWS_PROFILE>"
export TF_VAR_github_token="$(gh auth token)"

tofu init -backend-config=backend.hcl
tofu apply -input=false -var-file=../../tfvars/greenfield.tfvars
tofu output -raw remote_runner_cli_start_command
```

Full bring-up, CI wiring, and troubleshooting: [deployments README](../agent-pipeline-config/deployments/README.md).

## Prerequisites (checklist)

| Need | Walmart | Greenfield |
| --- | --- | --- |
| OpenTofu ≥ 1.6 | Yes | Yes |
| StackGen PAT + workspace UUID | Yes | Yes |
| AWS credentials | No (phase 1) | Yes (IAM + S3 state) |
| GitHub PAT | Customer (UI) | `TF_VAR_github_token` |
| Azure CLI | Customer (optional) | Yes (Reader SP) |
| Docker / runner image | Customer starts runner | `tofu output` start command |

Never commit tokens, SA JSON, `backend.hcl`, or Helm values that embed runner tokens.

## After apply — run a workflow

1. Confirm the remote runner is **online**.  
2. Confirm the runner image tag matches `script_pack_version` (rebuild after pack bumps).  
3. In StackGen, start one of:

| Workflow (intent) | Use when |
| --- | --- |
| `aws-cloud-discovery` | Discover AWS → split → reverse HCL → **AWS discovery PR** |
| `azure-migration-pr` | Generate Azure IaC from an existing discovery PR/branch (`source_pr`) |
| `gcp-migration-pr` | Generate GCP IaC from an existing discovery PR/branch (`source_pr`) |

Legacy names: `aws-migrator-discovery`, `aws-migrator-azure-only`, `aws-migrator-gcp-only` (see [12. I want to…](12-i-want-to.md)).

Discovery needs at least `aws_region` (for example `us-east-1`).

## Where PRs land in this repo

| Path | Contents |
| --- | --- |
| `aws/groups/<group_id>/` | Reverse-engineered AWS Terraform |
| `aws/artifacts/` | Manifests, split reports |
| `azure/groups/<group_id>/` | Catalog-driven Azure HCL |
| `azure/artifacts/` | Blueprint, living-gov SHA / findings / report |
| `gcp/groups/<group_id>/` | Catalog-driven GCP HCL |
| `gcp/artifacts/` | Blueprint, living-gov SHA / findings / report |

How to review those PRs: [Azure](07-reading-azure-prs.md) · [GCP](07b-reading-gcp-prs.md).

## Security (do not skip)

- Keep `*.tfvars`, `backend.hcl`, and local Helm/runner value files out of git.  
- Prefer **Reader-only** Azure SP and least-privilege GCP SA for live plan.  
- Rotate any StackGen / cloud token that was pasted into chat or tickets.  
- Docs and examples use placeholders like `<AWS_ACCOUNT_ID>` — never paste real account IDs or secrets into committed files.

## Next reading

1. [Mental model](01-mental-model.md) — what the pipeline is doing  
2. [Workflows & stages](04-workflows-and-stages.md) — discovery vs destination-only DAG  
3. [Day-2 ops](08-day-2-ops.md) — pack preload, triggers, troubleshooting
