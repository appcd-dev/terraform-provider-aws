# Naming conventions — aws-migrator

Three scopes. Do not mix them.

| Scope | Pattern | Owns |
|-------|---------|------|
| **Agent** | `aws-migrator-*` | agent, workflows, webhook, SOPs, evidence, runner, module runner secrets, script-pack home `.aws-migrator`, `generated_by=stackgen-aws-migrator` |
| **Cloud** | `cloud-{aws,github,azure,gcp}` | Guild MCP integrations + vault secrets — reusable across agents |
| **Deploy** | `stackgen-…-tramlaw` / `…-walle` | IAM role, Azure AD reader app, Terraform state key |
| **Destination** | `aws-to-azure` / `aws-to-gcp` | mapping catalogs only (`mappings/aws-to-*.json`) — not the product name |

## Canonical names

| Resource | Name |
|----------|------|
| Agent | `aws-migrator-architect` |
| Workflows | `aws-cloud-discovery`, `azure-migration-pr`, `gcp-migration-pr`, `aws-migrator-orphan-iac-module-authoring` |
| Webhook | `github-aws-migrator-receiver` |
| Runner | `aws-migrator-runner` |
| Module runner secrets | `aws-migrator-runner-{git,aws}-env` |
| Integrations | `cloud-aws`, `cloud-github`, `cloud-azure`, `cloud-gcp` |
| Integration vaults / runner env | `cloud-aws-vault`, `cloud-azure-runner-arm-env`, `cloud-gcp-runner-gcp-env` |
| Script pack | `/home/runner/.aws-migrator/script-pack/<ver>` |
| Intents | `aws-cloud-discovery`, `azure-migration-pr`, `gcp-migration-pr` |

### SOPs

- `aws-migrator-orchestration-sop`
- `aws-migrator-terraform-state-shard-extraction-sop`
- `aws-migrator-tfstate-splitter-sop`
- `aws-migrator-terraform-registry-reverse-iac-sop`
- `aws-migrator-terraform-substate-convergence-sop`
- `aws-migrator-azure-migration-profile-sop`
- `aws-migrator-orphan-iac-module-bootstrap-sop`
- `aws-migrator-cce-iac-alignment-sop`
- `cloud2code-aws-region-scan-sop` (shared cloud capability — not agent-prefixed)

### Deploy defaults (walle / tramlaw)

| Resource | Name |
|----------|------|
| IAM role | `stackgen-cloud-aws-readonly-tramlaw` |
| Azure AD app | `stackgen-cloud-azure-reader-walle` |
| TF state key | `tramlaw/aws-migrator.tfstate` |

## Cutover

Greenfield or full recreate: destroy under any legacy state key, re-init the prod state key, apply, register `aws-migrator-runner`, preload `.aws-migrator` script pack.
