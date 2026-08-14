# AWS Migrator Scenario

Deployment root for Demo Workspace on `https://walmart.cloud.stackgen.com`.

This root reuses:

- `demo-runner`
- `github-integration`
- `stackgen-sandbox`
- existing `dangerous-ops` policy `6aa4e036-5233-4678-b740-c6b0f588ed0f`
- existing Demo Workspace model registrations

It creates:

- `aws-migrator-architect`
- `aws-migrator-discovery`
- `aws-migrator-azure-only` / `aws-migrator-gcp-only` (destination half by intent)
- `aws-migrator-orphan-iac-module-authoring`
- the module's runbooks, evidence checklists, policy, and runner script-pack secret binding

It does not create AppStacks or attach a StackGen MCP integration; validation is standard Terraform/OpenTofu fmt, validate, optional tests, available lint, and zero-change plan evidence.

Generated workflow artifacts are pushed to `https://github.com/Walmart-StackGen/Nile-Factory.git`.
Pass `runner_git_token` during apply so `demo-runner` can push `split/<workflow_run_id>` and open the PR:

- `aws/groups/<group_id>/` - source-cloud Terraform roots and split state shards
- `aws/artifacts/` - manifests, `tfstate_monolith_decomposer.py`, split quality/tuning reports, review/layer summaries, orphan bundle, mappings, sampled group lists, and workflow notes
- `azure/` / `gcp/` - destination-cloud trees for the Azure / GCP migration phases

Apply with:

```bash
TF_VAR_stackgen_token='<PAT>' tofu init
TF_VAR_stackgen_token='<PAT>' TF_VAR_runner_git_token='<GITHUB_TOKEN>' tofu plan -out=tfplan
TF_VAR_stackgen_token='<PAT>' TF_VAR_runner_git_token='<GITHUB_TOKEN>' tofu apply tfplan
```
