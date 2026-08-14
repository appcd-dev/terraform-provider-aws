# AIOS Integration — GitHub

Provisions a GitHub SCM integration for repository operations, PRs, and code analysis.

## Usage

```hcl
module "github_integration" {
  source = "github.com/appcd-dev/solutions//modules/aios-integration-github"

  github_token = var.github_token
}
```

## Outputs

| Name | Description |
|------|-------------|
| `integration_name` | Name to pass to agent modules |
| `secret_id` | Vault secret ID |
