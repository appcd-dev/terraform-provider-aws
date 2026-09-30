# Deployments

OpenTofu roots under `deployments/` install the **AWS migrator** agent and related StackGen resources.

**Docs:** [docs hub](../../../docs/README.md) · [Walmart customer handoff](../../../docs/walmart-customer-handoff.md) · [day-2 ops](../../../docs/08-day-2-ops.md)

## Which root?

| Root | Use when |
| --- | --- |
| [`walmart/`](walmart/) | **Nile-Staging / customer-managed** — customer creates AWS/GitHub/Azure/GCP integrations and remote runner in StackGen UI. Two-phase apply: policy first, agent after handoff. |
| [`greenfield/`](greenfield/) | **Empty workspace you own** — Terraform creates IAM role, integrations, policy, remote runner, agent, and workflows. Needs AWS + Azure CLI creds. |
| [`examples/scenarios/aws-migrator/`](../examples/scenarios/aws-migrator/) | **Demo / reuse** — attach agent to existing runner, integrations, and policy by name. |

## Layout

```
deployments/
  README.md
  walmart/          ← Nile-Staging: customer-managed integrations (StackGen PAT only for phase 1)
  greenfield/       ← greenfield bring-up (IAM + integrations + runner created by TF)
../tfvars/
  walmart.tfvars    ← local only (*.tfvars gitignored)
  greenfield.tfvars
```

## Apply (walmart — Nile-Staging)

Single apply — integrations, vault secrets, and the remote runner already exist in the workspace, so this root looks them up by name and attaches the agent + workflows. Policy-only bootstrap (fresh workspace, no integrations yet): set `enable_agent_stack = false` and `enable_governance_codify = false`.

```bash
cd agent-pipeline-config/deployments/walmart

cat > ../../tfvars/walmart.tfvars <<'EOF'
stackgen_url        = "https://walmart.cloud.stackgen.com"
stackgen_token      = "<STACKGEN_PAT>"
stackgen_project_id = "<WORKSPACE_UUID>"
github_integration_name  = "<GITHUB_INTEGRATION>"   # e.g. cloud-github
github_secret_id         = "<GITHUB_VAULT_SECRET_UUID>"  # bound to runner typed github slot
aws_integration_name     = "<AWS_INTEGRATION>"       # e.g. vibe-aws-scanner
remote_runner_name       = "<RUNNER_NAME>"          # e.g. nile-runner
EOF

tofu init
tofu apply -input=false -var-file=../../tfvars/walmart.tfvars
tofu output dangerous_ops_policy_id
```

When the customer later creates or changes integrations/runner (or sends new names), edit the tfvars and re-apply:

```bash
tofu apply -input=false -var-file=../../tfvars/walmart.tfvars
tofu output script_pack_version
```

Full checklist: [walmart-customer-handoff.md](../../../docs/walmart-customer-handoff.md).

State defaults to **local** (`terraform.tfstate` in `walmart/`). For shared state, copy `backend.hcl.example` → `backend.hcl` and `tofu init -migrate-state -backend-config=backend.hcl`.

## Apply (greenfield)

Creates IAM role, Guild integrations, dangerous-ops policy, remote runner, agent, and workflows in one apply.

```bash
cd agent-pipeline-config/deployments/greenfield

cat > ../../tfvars/greenfield.tfvars <<'EOF'
stackgen_url        = "https://walmart.cloud.stackgen.com"
stackgen_token      = "<STACKGEN_PAT>"
stackgen_project_id = "<WORKSPACE_UUID>"
aws_account_id      = "<AWS_ACCOUNT_ID>"
EOF

cp backend.hcl.example backend.hcl   # replace placeholders
export AWS_PROFILE="<AWS_PROFILE>"
export TF_VAR_github_token="$(gh auth token)"
az account show >/dev/null

tofu init -backend-config=backend.hcl
tofu apply -input=false -var-file=../../tfvars/greenfield.tfvars
tofu output -raw remote_runner_cli_start_command
```

Historical note: `greenfield/` was previously named `walle` / `tramlaw`. Some IAM role and state-key **names** still use those strings so existing environments do not need forced replacement.

## CI apply (greenfield / Guild)

Workflow [`.github/workflows/tofu-apply-greenfield.yml`](../../../.github/workflows/tofu-apply-greenfield.yml) runs `tofu plan` / `tofu apply` for `greenfield/` against the **`guild`** GitHub Environment.

## Start the remote runner (greenfield only)

Workflows will not progress until the runner is online.

```bash
tofu output -raw remote_runner_cli_start_command
# run on a host with outbound access to StackGen; wait until runner is online in UI
```

For **walmart**, the customer starts the runner they registered in UI — TF does not output a start command.

## Run the agent

1. Open the workspace in StackGen.
2. Confirm integrations enabled and remote runner **online**.
3. Start **`aws-migrator-discovery`** with input `aws_region`.

## Troubleshooting

See sections in the previous README for stale state locks, AWS trust denied, agent model_names 400, policy create 400, and runner `E2BIG` / script pack mismatch. All still apply to `greenfield/`; walmart phase 1 only creates the policy so most runner/integration issues appear in phase 2 or on the customer side.

## Related docs

- [Agent module](../modules/aios-agent-aws-migrator/README.md)
- [Demo scenario](../examples/scenarios/aws-migrator/README.md)
- [Remote runner FAQ](../../../docs/10-remote-runner-faq.md)
