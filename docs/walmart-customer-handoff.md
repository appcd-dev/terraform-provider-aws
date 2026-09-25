# Walmart / Nile-Staging customer handoff

Use this checklist when the customer owns cloud integrations and the remote runner in StackGen UI. OpenTofu lives in [`deployments/walmart/`](../agent-pipeline-config/deployments/walmart/).

## Phase 1 (StackGen team — done once)

Apply with `enable_agent_stack = false` in [`tfvars/walmart.tfvars`](../agent-pipeline-config/tfvars/walmart.tfvars):

```bash
cd agent-pipeline-config/deployments/walmart
tofu init
tofu apply -input=false -var-file=../../tfvars/walmart.tfvars
tofu output dangerous_ops_policy_id
```

This creates the `dangerous-ops` logic policy in Nile-Staging. No AWS/Azure CLI creds required.

Optional phase 1b: set `enable_governance_codify = true` (with the customer's GitHub integration name) to install `governance-rules-codify` without the migrator agent stack.

## Phase 2 (customer — before agent apply)

Customer creates these in StackGen UI for workspace **Nile-Staging** (`bbc8f2a8-2586-45b7-ab64-6c69c9c34c02`):

| Item | Required | Notes |
| --- | --- | --- |
| GitHub Guild integration | Yes | PAT with `repo` + `read:org`; used for `gh api` on the architect |
| AWS Guild integration | Yes | Read-only role for `cloud2code` / discovery |
| Remote runner | Yes | Register + start with [Nile-Factory runner image](../../runner/README.md); outbound-only to `walmart.cloud.stackgen.com` |
| Azure Guild integration | Optional | Live `tofu plan` on generated Azure roots |
| GCP Guild integration | Optional | Live `tofu plan` on generated GCP roots |

### Runner prerequisites

- Image: `ghcr.io/walmart-stackgen/nile-factory-runner` (see [`runner/README.md`](../../runner/README.md) and Stackgen-Runner ACA)
- Script pack is **baked into the ACA image** (Walmart disables Guild vault secret sync). Image tag pack version must match `tofu output script_pack_version` after phase 2.
- Git + AWS credentials on the runner (customer configures via UI — TF does not create git/aws runner secrets in the walmart path)
- Runner status **online** in StackGen UI before starting workflows

### Hand back exact names

Customer sends the **integration names** and **runner name** as shown in StackGen (not display labels). Example:

```
github_integration_name = "cloud-github"
aws_integration_name    = "cloud-aws"
remote_runner_name      = "nile-staging-runner"
```

## Phase 2 apply (StackGen team)

1. Fill names in `tfvars/walmart.tfvars`
2. Set `enable_agent_stack = true`
3. Re-apply:

```bash
cd agent-pipeline-config/deployments/walmart
tofu plan  -var-file=../../tfvars/walmart.tfvars
tofu apply -input=false -var-file=../../tfvars/walmart.tfvars
tofu output script_pack_version
tofu output discovery_workflow_name
```

4. Confirm runner online and ACA image pack tag matches `script_pack_version`
5. Start **`aws-cloud-discovery`** (or the discovery workflow name from output) in StackGen UI

## Verify in UI

- [ ] `dangerous-ops` policy exists (phase 1)
- [ ] GitHub + AWS integrations enabled
- [ ] Remote runner online
- [ ] Agent `aws-migrator-architect` attached to integrations + runner (phase 2)
- [ ] Workflows `aws-cloud-discovery`, `azure-migration-pr`, `gcp-migration-pr` visible (names may match module outputs)

## When to use `greenfield` instead

If **Terraform** should create IAM roles, integrations, and register the runner (empty workspace, you own AWS/Azure creds), use [`deployments/greenfield/`](../agent-pipeline-config/deployments/greenfield/) instead of this path.
