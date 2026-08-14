# Deployments — empty StackGen workspace bring-up

Each subdirectory under `deployments/` is an OpenTofu root that installs the **AWS migrator** agent into a **greenfield** StackGen workspace. Unlike [`examples/scenarios/aws-migrator`](../examples/scenarios/aws-migrator/), these roots do **not** assume a pre-existing runner, integrations, policy, or model registry.

**Docs:** [docs hub](../../../docs/README.md) → [day-2 ops](../../../docs/08-day-2-ops.md) for apply / preload / troubleshoot.

## What a deployment creates

| Resource | Purpose |
| --- | --- |
| AWS IAM role (`ReadOnlyAccess` + Deny unmappable) | Assumed by Guild AWS MCP / cloud2code; Deny blocks IAM user/group/SAML/OIDC, Athena, and EC2 key-pair reads that never map to Azure/GCP |
| `sg_guild_integration` (AWS) | Read-only AWS discovery for `cloud2code` / plan hydration |
| GitHub integration | Clone + PR into the IaC repository (`cloud-migrator` by default) |
| Azure Reader SP + Guild Azure integration | Live `tofu plan` in the customer subscription (Reader only; never apply migration IaC) |
| Runner `ARM_*` vault secret | Bound via `sg_remote_runner_secrets` so validate sees ARM env keys |
| Optional GCP SA + Guild GCP integration | Live `tofu plan` when `gcp_credentials_json` + `gcp_project_id` are set in tfvars |
| Runner GCP ADC vault secret | Bound for `gcp-iac-validate` when GCP live plan is enabled |
| `dangerous-ops` logic policy | Denies destructive / off-hours high-risk shell so HITL can gate it |
| Remote runner (`create_remote_runner = true`) | Runs the migration script pack (`cloud2code`, tofu, git, …) |
| Agent + workflows | Architect agent, discovery, azure-only, gcp-only, orphan authoring |

Models: **omit `model_names` by default**. Guild falls back to its built-in default provider. Optionally set `azure_openai_api_url` + `azure_openai_api_key` and list deployments in `azure_openai_models` (no presets) to register an Azure OpenAI (`provider_type = openai`) provider and attach those names to the agent.

## Layout

```
deployments/
  README.md                 ← this file
  walle/                  ← example: greenfield StackGen workspace bring-up (set YOUR AWS account in tfvars / backend.hcl)
    main.tf
    models_azure_openai.tf  ← optional Azure OpenAI provider + models (URL+key + explicit list)
    providers.tf
    backend.tf              ← S3 state + lockfile in the target AWS account
    variables.tf
    outputs.tf
    policies/dangerous-ops.rego
../tfvars/
  <name>.tfvars             ← local only (repo gitignores *.tfvars)
```

## Prerequisites

1. **OpenTofu** (or Terraform) with network access to `releases.stackgen.com` for the StackGen provider.
2. **AWS named profile** that can:
   - create/update the IAM role in the target account
   - read/write the S3 state bucket declared in `backend.tf`
3. **StackGen PAT** with rights to create secrets, integrations, policies, agents, workflows, and remote runners in the target workspace.
4. **GitHub PAT** with `repo` and `read:org` (used for the Guild GitHub integration and `runner_git_token`).
5. **Azure CLI** (`az login`) or ARM_* / AZURE_* env with rights to create an AD app and assign **Reader** at subscription scope. Apply creates the Reader SP + Guild Azure integration + runner ARM_* secret; it does **not** apply generated migration IaC.
6. **Optional GCP SA JSON** (`gcp_credentials_json` + `gcp_project_id` in tfvars) to create the GCP integration + runner ADC secret and enable `require_gcp_live_plan`. Omit to skip GCP live-plan wiring.
7. **Optional Azure OpenAI** (`azure_openai_api_url` + `azure_openai_api_key`, plus at least one entry in `azure_openai_models`) to register an openai-compatible provider and attach those models to the agent. Omit all three for Guild's built-in default. There are **no default models** — list Azure deployment names explicitly.
8. **Docker** (or Helm) to start `aiden-runner` after apply.

## CI apply (GitHub Actions)

Workflow [`.github/workflows/tofu-apply-walle.yml`](../../../.github/workflows/tofu-apply-walle.yml) runs `tofu plan` / `tofu apply` for this root against the **`guild`** GitHub Environment.

| Item | Source |
| --- | --- |
| `STACKGEN_TOKEN` | Environment **secret** |
| `STACKGEN_URL` / `STACKGEN_PROJECT_ID` / `AWS_ACCOUNT_ID` | Environment **variables** |
| AWS (state + IAM) | OIDC → `vars.AWS_ROLE_ARN` (`github-actions-cloud-migrator-tofu`) |
| `TF_STATE_BUCKET` / `TF_STATE_KEY` / `AWS_REGION` | Environment **variables** → `tofu init -backend-config=…` |
| `TF_GITHUB_TOKEN` | Environment **secret** (Guild GitHub integration + runner git) |
| `ARM_*` | Environment **secrets** (azurerm / azuread) |
| `GCP_CREDENTIALS_JSON` | Environment **secret** (optional live-plan wiring) |

Triggers: `workflow_dispatch` (optional plan-only) and pushes to `main` / `feat/aws-azure-mapping-catalog` that touch `agent-pipeline-config/**`.

`backend.tf` is a **partial** S3 backend (encrypt + lockfile only). State bucket/key/region are not hardcoded — CI injects them from `guild` vars; locally copy `backend.hcl.example` → `backend.hcl` (gitignored) and `tofu init -backend-config=backend.hcl`.

## Apply (walle)

```bash
cd agent-pipeline-config/deployments/walle

# Local tfvars — never commit (*.tfvars is gitignored)
cat > ../../tfvars/walle.tfvars <<'EOF'
stackgen_url        = "https://walmart.cloud.stackgen.com"
stackgen_token      = "<STACKGEN_PAT>"
stackgen_project_id = "<WORKSPACE_UUID>"
aws_account_id      = "<AWS_ACCOUNT_ID>"
# Optional Azure OpenAI (no default models — list deployments explicitly):
# azure_openai_api_url = "https://<resource>.openai.azure.com"
# azure_openai_api_key = "<AZURE_OPENAI_KEY>"
# azure_openai_models = [
#   { name = "azure-gpt-4o", model_id = "gpt-4o", good_for_task = "tool_calling" },
# ]
EOF

# Local backend overrides — never commit (backend.hcl is gitignored)
cp backend.hcl.example backend.hcl   # replace <AWS_ACCOUNT_ID> / <AWS_PROFILE> placeholders

export AWS_PROFILE="<AWS_PROFILE>"
export TF_VAR_github_token="$(gh auth token)"
# Ensure Azure provider auth (Reader SP create + role assignment only):
az account show >/dev/null

tofu init -backend-config=backend.hcl
tofu plan  -var-file=../../tfvars/walle.tfvars
tofu apply -input=false -var-file=../../tfvars/walle.tfvars
```

After apply, restart or wait for runner secret sync so `ARM_*` (and GCP ADC keys when enabled) appear on the runner. With `require_azure_live_plan=true` / `require_gcp_live_plan=true`, `*_plan_status=skipped:missing_credentials` fails the validate stage.
Historical note: the `walle` directory was previously named `tramlaw`. Some IAM role / state-key **names** still use that string so existing environments do not need a forced replacement; they are not cloud account IDs.

Useful outputs:

```bash
tofu output aws_role_arn
tofu output aws_integration_name
tofu output github_integration_name
tofu output -raw remote_runner_cli_start_command   # sensitive — start the runner with this
```

## Start the remote runner

Workflows will not progress until the runner is online.

```bash
# Print the copy-paste start command (Docker / aiden-runner CLI)
tofu output -raw remote_runner_cli_start_command

# Run it on a host that can reach the StackGen URL outbound.
# In the StackGen UI, wait until the runner status is online.
```

If your root also exposes Helm (scenario roots do), use:

```bash
tofu output -raw remote_runner_helm_install_command
```

The module binds a script-pack secret to the runner. Do not try to stuff the pack into runner env vars (risk of `E2BIG`); preload under `/home/runner/.aws-migrator/script-pack/<version>` as documented in the [agent module README](../modules/aios-agent-aws-migrator/README.md).

## Run the agent

1. Open the workspace in StackGen (`stackgen_url` + project from tfvars).
2. Confirm integrations are enabled and the remote runner is **online**.
3. Start **`aws-migrator-discovery`** with input `aws_region` (required). Optional: `cloud2code_include` / `exclude` / `tags`.
4. Or start **`aws-migrator-azure-only`** to retest Azure stages from an existing `split/...` branch in this repo.

Generated PRs update `aws/` and `azure/` in [cloud-migrator](https://github.com/Walmart-StackGen/Nile-Factory).

## Clone this deployment for another workspace

1. Copy `walle/` to `deployments/<new-name>/`.
2. Create `backend.hcl` (from `backend.hcl.example`) with a unique S3 bucket/key/region/profile — or set `TF_STATE_*` on the GitHub Environment used by CI.
3. Edit defaults in `variables.tf` if you need a different IAM role name, integration names, or IaC repo URL.
4. Add `../tfvars/<new-name>.tfvars` with that workspace’s `stackgen_url`, `stackgen_token`, and `stackgen_project_id`.
5. Point `AWS_PROFILE` at an account that owns both the IAM role and the state bucket.
6. `tofu init -backend-config=backend.hcl && tofu apply -var-file=../../tfvars/<new-name>.tfvars`.

Keep one OpenTofu state per workspace. Do not share a state key across workspaces.

## Troubleshooting

### Stale state lock (`412 PreconditionFailed` / Error acquiring the state lock)

With `use_lockfile = true`, an interrupted apply can leave `*.tfstate.tflock` in S3. **Only unlock when no apply is actually running:**

```bash
ps aux | grep -E '[t]ofu|[t]erraform'   # should not show an apply process
tofu force-unlock -force <LOCK_ID>      # ID is in the error message
```

Then re-run `tofu apply`. Prefer `force-unlock` over `-lock=false`.

### AWS vault secret `ASSUME_ROLE_TRUST_DENIED`

IAM role trust or StackGen bastion propagation can lag right after role create. Wait ~30–60s and re-apply. Confirm the role trust policy matches `data.sg_vault_aws_config.workspace.trust_policy` and that `external_id` is present on the vault secret metadata.

### Agent `model_names` 400 on update

Do not pass unregistered model names. Leave `model_names` empty (default) so Guild uses the built-in default, or enable Azure OpenAI and list only names you also register via `azure_openai_models`. Passing a name that is not in the workspace registry succeeds on create (silently dropped) but fails on later updates.

### Policy create 400

Guild `logic` policies must expose `allow` / `deny` (not only `approval_required`). The Rego under `policies/dangerous-ops.rego` already follows that contract.

### Runner online but shell fails with `E2BIG` or `preload_sha256_mismatch`

Re-preload the script pack at the version embedded in the module (`local.script_pack_version`) and bump that version whenever pack files change. See the [agent module README](../modules/aios-agent-aws-migrator/README.md).

## Related docs

- [Root README](../../README.md) — repo map and quick start
- [Agent module](../modules/aios-agent-aws-migrator/README.md) — workflow stages, mapping catalog, runner credentials
- [Demo scenario](../examples/scenarios/aws-migrator/README.md) — reuse existing Demo Workspace assets instead of creating them
